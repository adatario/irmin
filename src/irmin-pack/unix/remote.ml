(*
 * Copyright (c) 2023 Tarides <contact@tarides.com>
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

module Make (Commit : Irmin.Type.S) (Branch : Irmin.Type.S) = struct
  type t = unit

  let v _ = Lwt.return_unit

  type endpoint = unit
  type commit = Commit.t
  type branch = Branch.t

  let fetch () ?depth:_ _ _br =
    Lwt.return (Error (`Msg "fetch operation is not available"))

  let push () ?depth:_ _ _br =
    Lwt.return (Error (`Msg "push operation is not available"))

  (* The core idea is to add functional accessors for remotes.

       Instead of fetch that adds a commit to the local repo. find_*
     returns an in-memory representation of the requested object. *)

  let find_node remote key : Node.t option = failwith "TODO"
  let find_commit remote key : Commit.t option = failwith "TODO"
end
