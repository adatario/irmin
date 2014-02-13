(*
 * Copyright (c) 2013 Thomas Gazagnaire <thomas@gazagnaire.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open Lwt
open Core_kernel.Std

module Log = Log.Make(struct let section = "GIT" end)

module Make (G: Git.Store.S) (K: IrminKey.S) (B: IrminBlob.S) (R: IrminReference.S) = struct

  let git_of_key key =
    Git.SHA1.of_string (K.to_raw key)

  let key_of_git key =
    K.of_raw (Git.SHA1.to_string key)

  module XInternal = struct

    module type V = sig
      type t
      val type_eq: Git.Object_type.t -> bool
      val to_git: G.t -> t -> [`Value of Git.Value.t Lwt.t | `Key of Git.SHA1.t]
      val of_git: Git.SHA1.t -> Git.Value.t -> t option
    end

    (* caching the state to avoid state duplication when it is hold in memory *)
    let cache = ref None

    module AO (V: V) = struct

      type t = G.t

      type key = K.t

      type value = V.t

      let create () =
        match !cache with
        | Some t -> t
        | None   ->
          let t = G.create () in
          cache := Some t;
          t

      let mem t key =
        Log.debugf "Tree.mem %s" (K.to_string key);
        let key = git_of_key key in
        G.mem t key >>= function
        | false    -> return false
        | true     ->
          G.read t key >>= function
          | None   -> return false
          | Some v -> return (V.type_eq (Git.Value.type_of v))

      let read t key =
        Log.debugf "Tree.read %s" (K.to_string key);
        let key = git_of_key key in
        G.read t key >>= function
        | None   -> return_none
        | Some v -> return (V.of_git key v)

      let read_exn t key =
        read t key >>= function
        | None   -> fail Not_found
        | Some v -> return v

      let list t k =
        return [k]

      let contents t =
        G.list t >>= fun keys ->
        Lwt_list.fold_left_s (fun acc k ->
            G.read_exn t k >>= fun v ->
            match V.of_git k v with
            | None   -> return acc
            | Some v -> return ((key_of_git k, v) :: acc)
          ) [] keys

      let add t v =
        match V.to_git t v with
        | `Key k   -> return (key_of_git k)
        | `Value v ->
          v >>= fun v ->
          G.write t v >>= fun k ->
          return (key_of_git k)

    end

    module XBlob = AO (struct

        type t = B.t

        let type_eq = function
          | Git.Object_type.Blob
          | Git.Object_type.Tag -> true
          | _ -> false

        let of_git k b =
          Log.debugf "Blob.of_git: %S" (Git.Value.pretty b);
          match b with
          | Git.Value.Blob b -> Some (B.of_string (Git.Blob.to_string b))
          | Git.Value.Tag _  -> None (* XXX: deal with tag objects *)
          | _                -> None

        let to_git _ b =
          Log.debugf "Blob.to_git %S" (B.to_string b);
          let value = Git.Value.Blob (Git.Blob.of_string (B.to_string b)) in
          `Value (return value)

      end)

    module XTree = AO(struct

        type t = K.t IrminTree.t

        module X = IrminTree.S(K)

        let type_eq = function
          | Git.Object_type.Blob
          | Git.Object_type.Tree -> true
          | _ -> false

        let escape = Char.of_int_exn 42

        let escaped_chars =
          escape :: List.map ~f:Char.of_int_exn [ 0x00; 0x2f ]

        let needs_escape = List.mem escaped_chars

        let encode path =
          if not (String.exists ~f:needs_escape path) then
            path
          else (
            let n = String.length path in
            let b = Buffer.create n in
            let last = ref 0 in
            for i = 0 to n - 1 do
              if needs_escape path.[i] then (
                let c = Char.of_int_exn (Char.to_int path.[i] + 1) in
                if i - 1 - !last > 1 then Buffer.add_substring b path !last (i - 1 - !last);
                Buffer.add_char b escape;
                Buffer.add_char b c;
                last := i + 1;
              )
            done;
            if n - 1 - !last > 1 then
              Buffer.add_substring b path !last (n - 1 - !last);
            Buffer.contents b
          )

        let decode path =
          if not (String.mem path escape) then path
          else
            let l = String.split ~on:escape path in
            let l =
              List.map ~f:(fun s ->
                if String.length s > 0 then
                  match Char.of_int (Char.to_int s.[0] - 1) with
                  | None   -> s
                  | Some c ->
                    if needs_escape c then (s.[0] <- c; s)
                    else s
                else
                  s
              ) l in
            String.concat ~sep:"" l

        let of_git k v =
          Log.debugf "Tree.of_git %s" (Git.Value.pretty v);
          match v with
          | Git.Value.Blob _ ->
            (* Create a dummy leaf node to hold blobs. *)
            let key = key_of_git k in
            Some (IrminTree.Leaf key)
          | Git.Value.Tree t ->
            let children =
              List.map ~f:(fun e -> Git.Tree.(decode e.name, key_of_git e.node))
                t in
            Some (IrminTree.Node children)
          | _ -> None

        let to_git t tree =
          Log.debugf "Tree.to_git %s" (X.to_string tree);
          match tree with
          | IrminTree.Leaf key ->
            (* This is a dummy leaf node. Do nothing. *)
            Log.debugf "Skiping %s" (X.to_string tree);
            `Key (git_of_key key)
          | IrminTree.Node children ->
            `Value (
              Lwt_list.map_p (fun (name, key) ->
                  let name = encode name in
                  let node = git_of_key key in
                  (* XXX: handle exec files. *)
                  let file () = return { Git.Tree.perm = `Normal; name; node } in
                  let dir ()  = return { Git.Tree.perm = `Dir   ; name; node } in
                  G.read t node >>= function
                  | None   -> dir () (* on import, the children nodes migh not
                                        have been loaded properly yet. *)
                  | Some v ->
                    match Git.Value.type_of v with
                    | Git.Object_type.Blob -> file ()
                    | Git.Object_type.Tree -> dir ()
                    | _                    -> fail (Failure "Tree.to_git")
                ) children >>= fun entries ->
              return (Git.Value.Tree entries)
            )

      end)

    module XCommit = AO(struct

        type t = K.t IrminCommit.t

        module X = IrminCommit.S(K)

        let type_eq = function
          | Git.Object_type.Commit -> true
          | _ -> false

        let of_git k v =
          Log.debugf "Commit.of_git %s" (Git.Value.pretty v);
          match v with
          | Git.Value.Commit { Git.Commit.tree; parents; author } ->
            let commit_key_of_git k = key_of_git (Git.SHA1.of_commit k) in
            let tree_key_of_git k = key_of_git (Git.SHA1.of_tree k) in
            let parents = List.map ~f:commit_key_of_git parents in
            let tree = Some (tree_key_of_git tree) in
            let origin = author.Git.User.name in
            let date = match String.split ~on:' ' author.Git.User.date with
              | [date;_] -> Float.of_string date
              | _        -> 0. in
            Some { IrminCommit.tree; parents; date; origin }
          | _ -> None

        let to_git _ c =
          Log.debugf "Commit.to_git %s" (X.to_string c);
          let { IrminCommit.tree; parents; date; origin } = c in
          match tree with
          | None      -> failwith "Commit.to_git: not supported"
          | Some tree ->
            let git_of_commit_key k = Git.SHA1.to_commit (git_of_key k) in
            let git_of_tree_key k = Git.SHA1.to_tree (git_of_key k) in
            let tree = git_of_tree_key tree in
            let parents = List.map ~f:git_of_commit_key parents in
            let date = Int64.to_string (Float.to_int64 date) ^ " +0000" in
            let author =
              Git.User.({ name  = origin;
                               email = "irminsule@openmirage.org";
                               date;
                             }) in
            let message = "Autogenerated by Irminsule" in
            let commit = {
              Git.Commit.tree; parents;
              author; committer = author;
              message } in
            let value = Git.Value.Commit commit in
            `Value (return value)

      end)

    include IrminValue.Mux(K)(B)(XBlob)(XTree)(XCommit)

  end

  module XReference = struct

    type t = G.t

    type key = R.t

    type value = K.t

    let create () =
      G.create ()

    let ref_of_git r =
      R.of_string (Git.Reference.to_string r)

    let git_of_ref r =
      Git.Reference.of_string (R.to_string r)

    let mem t r =
      G.mem_reference t (git_of_ref r)

    let key_of_git k = key_of_git (Git.SHA1.of_commit k)

    let read t r =
      G.read_reference t (git_of_ref r) >>= function
      | None   -> return_none
      | Some k -> return (Some (key_of_git k))

    let read_exn t r =
      G.read_reference_exn t (git_of_ref r) >>= fun k ->
      return (key_of_git k)

    let list t _ =
      G.references t >>= fun refs ->
      return (List.map ~f:ref_of_git refs)

    let contents t =
      G.references t >>= fun refs ->
      Lwt_list.map_p (fun r ->
          G.read_reference_exn t r >>= fun k ->
          return (ref_of_git r, key_of_git k)
        ) refs

    let git_of_key k = Git.SHA1.to_commit (git_of_key k)

    let update t r k =
      G.write_reference t (git_of_ref r) (git_of_key k)

    let remove t r =
      G.remove_reference t (git_of_ref r)

    module Key = R

    module Value = K

  end

  include Irmin.Make(K)(B)(R)(XInternal)(XReference)

end

module String(G: Git.Store.S) =
  Make(G)(IrminKey.SHA1)(IrminBlob.String)(IrminReference.String)

module JSON(G: Git.Store.S) =
  Make(G)(IrminKey.SHA1)(IrminBlob.JSON)(IrminReference.String)

let create k g =
  let (module G) = match g with
    | `Local  -> (module Git_fs    : Git.Store.S)
    | `Memory -> (module Git_memory: Git.Store.S)
  in
  match k with
  | `String -> (module String(G): Irmin.S)
  | `JSON   -> (module JSON(G)  : Irmin.S)
