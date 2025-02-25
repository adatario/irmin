open Notty
open Notty_unix
open Import
open Files
module Files = Make (Irmin_tezos.Conf) (Irmin_tezos.Schema)

type entry_content = {
  hash : string;
  kind : Kind.t;
  off : Int63.t;
  length : int;
  contents : string;
}

type entry_ctx = { last : info; next : info }
and info = { commit : int list; contents : int list; inode : int list }

type context = {
  info_last_fd : Unix.file_descr;
  info_next_fd : Unix.file_descr;
  idxs : (int * (Int63.t * Int63.t) * Int63.t) list;
  fm : Files.File_manager.t;
  dispatcher : Files.Dispatcher.t;
  dict : string list;
  max_entry : int;
  max_offset : Int63.t;
  mutable entry : int;
  mutable entry_ctx : entry_ctx;
  mutable entry_content : entry_content;
  mutable x : int;
  mutable y : int;
}

let buffer = Bytes.create (4096 * 4096)

let get_entry c off =
  let hash, kind, length, contents =
    Files.decode_entry c.dispatcher buffer off
  in
  let hash = Result.get_ok @@ Base64.encode hash in
  { hash; kind; off; length; contents }

let read ~fd ~buffer ~fd_offset ~buffer_offset ~length =
  let rec aux fd_offset buffer_offset length read_count =
    let r =
      Index_unix.Syscalls.pread ~fd ~fd_offset ~buffer ~buffer_offset ~length
    in
    let read_count = read_count + r in
    if r = 0 then read_count (* end of file *)
    else if r = length then read_count
    else
      (aux [@tailcall])
        (Int63.add fd_offset (Int63.of_int r))
        (buffer_offset + r) (length - r) read_count
  in
  aux fd_offset buffer_offset length 0

let load_idxs fd =
  let idx = ref 0 in
  let _ =
    read ~fd ~buffer ~fd_offset:Int63.zero ~buffer_offset:0
      ~length:Varint.max_encoded_size
  in
  let buf = Bytes.unsafe_to_string buffer in
  let max_entry = Varint.decode_bin buf idx in
  let idxs =
    List.init max_entry (fun i ->
        let _ =
          read ~fd ~buffer ~fd_offset:(Int63.of_int !idx) ~buffer_offset:0
            ~length:(Varint.max_encoded_size * 3)
        in
        let buffer = Bytes.unsafe_to_string buffer in
        let i' = ref 0 in
        let off_last_info = Int63.of_int @@ Varint.decode_bin buffer i' in
        let off_next_info = Int63.of_int @@ Varint.decode_bin buffer i' in
        let off_pack = Int63.of_int @@ Varint.decode_bin buffer i' in
        idx := !i' + !idx;
        (i, (off_last_info, off_next_info), off_pack))
  in
  (max_entry, idxs)

let load_entry fd_last fd_next (fd_offset_last, fd_offset_next) =
  let _ =
    read ~fd:fd_last ~buffer ~fd_offset:fd_offset_last ~buffer_offset:0
      ~length:(Varint.max_encoded_size * 7)
  in
  let buf = Bytes.unsafe_to_string buffer in
  let idx = ref 0 in
  let flag = Varint.decode_bin buf idx in
  let n = Int.logand flag 0b11 in
  let commit = List.init n (fun _ -> Varint.decode_bin buf idx) in
  let n = Int.shift_right_logical (Int.logand flag 0b1100) 2 in
  let contents = List.init n (fun _ -> Varint.decode_bin buf idx) in
  let n = Int.shift_right_logical (Int.logand flag 0b110000) 4 in
  let inode = List.init n (fun _ -> Varint.decode_bin buf idx) in
  let last = { commit; contents; inode } in
  let _ =
    read ~fd:fd_next ~buffer ~fd_offset:fd_offset_next ~buffer_offset:0
      ~length:(Varint.max_encoded_size * 7)
  in
  let buf = Bytes.unsafe_to_string buffer in
  let idx = ref 0 in
  let flag = Varint.decode_bin buf idx in
  let n = Int.logand flag 0b11 in
  let commit = List.init n (fun _ -> Varint.decode_bin buf idx) in
  let n = Int.shift_right_logical (Int.logand flag 0b1100) 2 in
  let contents = List.init n (fun _ -> Varint.decode_bin buf idx) in
  let n = Int.shift_right_logical (Int.logand flag 0b110000) 4 in
  let inode = List.init n (fun _ -> Varint.decode_bin buf idx) in
  let next = { commit; contents; inode } in
  { last; next }

let reload_context c i =
  let _, off_info, off_pack = List.nth c.idxs i in
  c.entry <- i;
  c.entry_ctx <- load_entry c.info_last_fd c.info_next_fd off_info;
  c.entry_content <- get_entry c off_pack

let reload_context_with_off c off =
  let entry, idx, _ =
    Option.get
    @@ List.find_opt (fun (_, _, off') -> Int63.equal off off') c.idxs
  in
  c.entry <- entry;
  c.entry_ctx <- load_entry c.info_last_fd c.info_next_fd idx;
  c.entry_content <- get_entry c off

module Menu = struct
  let button_attr b b' =
    match (b, b') with
    | true, true -> A.(bg lightwhite ++ fg black)
    | true, false -> A.(fg lightwhite)
    | false, true -> A.(fg @@ gray 16)
    | false, false -> A.(fg @@ gray 8)

  let button s a h =
    let attr = button_attr a h in
    I.string attr s

  let back_str =
    [|
      ("◂──", "Go back by 1000 ");
      ("◂─", "Go back by 10 ");
      ("◂", "Go back by 1 ");
    |]

  let forth_str =
    [|
      ("▸", "Go forth by 1 ");
      ("─▸", "Go forth by 10 ");
      ("──▸", "Go forth by 1000 ");
    |]

  let gen_entry_buttons r c str =
    let l = [ 1; 10; 1000 ] in
    let f i c = reload_context c i in
    Array.mapi
      (fun i (button_txt, tooltip) ->
        let i = if r then 2 - i else i in
        let tooltip = tooltip ^ if i <> 0 then "entries" else "entry" in
        let i = List.nth l i in
        if r && c.entry - i >= 0 then
          let e = c.entry - i in
          (button button_txt true, f e, tooltip, Some e)
        else if (not r) && c.entry + i < c.max_entry then
          let e = c.entry + i in
          (button button_txt true, f e, tooltip, Some e)
        else (button button_txt false, (fun _ -> ()), tooltip, None))
      str

  let gen_buttons r s l str =
    let f i c = if i <> -1 then reload_context c i in
    Array.mapi
      (fun i (button_txt, tooltip) ->
        let i = if r then 2 - i else i in
        let tooltip = tooltip ^ s ^ if i <> 0 then "s" else "" in
        if i < List.length l then
          let e = List.nth l i in
          (button button_txt true, f e, tooltip, Some e)
        else (button button_txt false, (fun _ -> ()), tooltip, None))
      str

  let text_button s = (button s true, (fun _ -> ()), s, None)

  let b c =
    [|
      Array.concat
        [
          gen_entry_buttons true c back_str;
          [| text_button "Entry  " |];
          gen_entry_buttons false c forth_str;
        ];
      Array.concat
        [
          gen_buttons true "commit" c.entry_ctx.last.commit back_str;
          [| text_button "Commit " |];
          gen_buttons false "commit" c.entry_ctx.next.commit forth_str;
        ];
      Array.concat
        [
          gen_buttons true "content" c.entry_ctx.last.contents back_str;
          [| text_button "Content" |];
          gen_buttons false "content" c.entry_ctx.next.contents forth_str;
        ];
      Array.concat
        [
          gen_buttons true "inode" c.entry_ctx.last.inode back_str;
          [| text_button "Inode  " |];
          gen_buttons false "inode" c.entry_ctx.next.inode forth_str;
        ];
    |]

  let buttons b ~x_off ~y_off x y =
    let _, b =
      Array.fold_left
        (fun (y', acc) a ->
          let l =
            List.rev
            @@ snd
            @@ Array.fold_left
                 (fun (x', acc) (f, _, _, _) ->
                   (x' + 1, (f (x' = x && y' = y) |> I.pad ~l:1 ~t:0) :: acc))
                 (0, []) a
          in
          (y' + 1, I.hcat l :: acc))
        (0, []) b
    in
    I.(pad ~l:x_off ~t:y_off @@ vcat (List.rev b))

  let bound m x = (x + m) mod m

  let move b c = function
    | `Left -> c.x <- bound (Array.length b.(c.y)) (c.x - 1)
    | `Right -> c.x <- bound (Array.length b.(c.y)) (c.x + 1)
    | `Up ->
        c.y <- bound (Array.length b) (c.y - 1);
        c.x <- bound (Array.length b.(c.y)) c.x
    | `Down ->
        c.y <- bound (Array.length b) (c.y + 1);
        c.x <- bound (Array.length b.(c.y)) c.x
end

module Button = struct
  type 'a t = { x : int; y : int; w : int; h : int; f : 'a }

  let on_press (x, y) b =
    if x >= b.x && x < b.x + b.w && y >= b.y && y < b.y + b.h then Some b.f
    else None

  let pad b x y = { b with x = b.x + x; y = b.y + y }
end

let menu_box h w =
  let open I in
  let bar = String.concat "" @@ List.init (w + 2) (fun _ -> "━") in
  let t_bar = "┏" ^ bar ^ "┓" in
  let m_bar = "┃" ^ String.make (w + 2) ' ' ^ "┃" in
  let mf_bar = "┣" ^ bar ^ "┫" in
  let b_bar = "┗" ^ bar ^ "┛" in
  let middle =
    I.vcat (List.init h (fun _ -> string A.(fg white ++ st bold) m_bar))
  in
  string A.(fg white ++ st bold) t_bar
  <-> middle
  <-> string A.(fg white ++ st bold) mf_bar
  <-> string A.(fg white ++ st bold) m_bar
  <-> string A.(fg white ++ st bold) b_bar

let position_text c i =
  match i with
  | None -> I.empty
  | Some i ->
      let d = i - c.entry in
      let entry_txt = if d = -1 || d = 1 then "entry" else "entries" in
      let _, _, off_pack = List.nth c.idxs i in
      let content = get_entry c off_pack in
      let open I in
      let color, text =
        match content.kind with
        | Commit_v1 | Commit_v2 -> (A.red, "Commit")
        | Dangling_parent_commit -> (A.magenta, "Dangling commit")
        | Contents -> (A.lightblue, "Contents")
        | Inode_v1_unstable | Inode_v1_stable | Inode_v2_root | Inode_v2_nonroot
          ->
            (A.green, "Inode")
      in
      let arrow =
        if d < 0 then
          string A.(fg color ++ st bold) text
          <|> string A.(fg lightwhite ++ st bold) " ◀━━━▪"
        else
          string A.(fg lightwhite ++ st bold) "▪━━━▶ "
          <|> string A.(fg color ++ st bold) text
      in
      arrow
      <-> void 0 1
      <-> string
            A.(fg lightwhite ++ st bold)
            ("by " ^ Int.to_string (abs d) ^ " " ^ entry_txt)
      <-> void 0 1
      <-> string
            A.(fg lightwhite ++ st bold)
            ("to offset " ^ Int63.to_string off_pack)
      |> pad ~l:30 ~t:1

let position_box h w =
  let open I in
  let bar = String.concat "" @@ List.init (w + 2) (fun _ -> "━") in
  let t_bar = "┏" ^ bar ^ "┓" in
  let m_bar = "┃" ^ String.make (w + 2) ' ' ^ "┃" in
  let b_bar = "┗" ^ bar ^ "┛" in
  let middle =
    I.vcat (List.init h (fun _ -> string A.(fg white ++ st bold) m_bar))
  in
  string A.(fg white ++ st bold) t_bar
  <-> middle
  <-> string A.(fg white ++ st bold) b_bar

let show_commit c (commit : Files.Commit.Commit_direct.t) =
  let node_txt = I.string A.(fg lightred ++ st bold) "Node:" in
  let addr_show (addr : Files.Commit.Commit_direct.address) =
    match addr with
    | Offset addr -> (
        let hit_or_miss =
          List.find_opt (fun (_, _, off) -> Int63.equal addr off) c.idxs
        in
        match hit_or_miss with
        | None ->
            ( I.strf
                ~attr:A.(fg lightwhite ++ st bold)
                "Dangling entry (off %a)" Int63.pp addr,
              [] )
        | Some (idx, _, off_pack) ->
            let img =
              let content = get_entry c off_pack in
              let open I in
              let color, text =
                match content.kind with
                | Commit_v1 | Commit_v2 -> (A.red, "Commit")
                | Dangling_parent_commit -> (A.magenta, "Dangling commit")
                | Contents -> (A.lightblue, "Contents")
                | Inode_v1_unstable | Inode_v1_stable | Inode_v2_root
                | Inode_v2_nonroot ->
                    (A.green, "Inode")
              in
              I.strf ~attr:A.(fg lightwhite ++ st bold) "Entry %d (" idx
              <|> I.string A.(fg color ++ st bold) text
              <|> I.strf
                    ~attr:A.(fg lightwhite ++ st bold)
                    ", off %a)" Int63.pp addr
            in
            ( img,
              [
                Button.
                  {
                    x = 0;
                    y = 0;
                    w = I.width img;
                    h = 1;
                    f = (fun c -> reload_context_with_off c addr);
                  };
              ] ))
    | Hash _hash ->
        (I.string A.(fg lightwhite ++ st bold) "Hash <should not happen>", [])
  in
  let node, node_button = addr_show commit.node_offset in
  let parents_txt = I.string A.(fg lightred ++ st bold) "Parents:" in
  let parents, parents_buttons =
    match commit.parent_offsets with
    | [] -> (I.string A.(fg lightwhite ++ st bold) "none", [])
    | parents ->
        let l_img, l_buttons =
          List.split
            (List.mapi
               (fun i addr ->
                 let node, node_button = addr_show addr in
                 (node, List.map (fun b -> Button.pad b 0 i) node_button))
               parents)
        in
        (I.hcat l_img, l_buttons)
  in
  let info_txt = I.string A.(fg lightred ++ st bold) "Info:" in
  let info = commit.info in
  let date =
    Option.get
    @@ Ptime.of_span
    @@ Ptime.Span.of_int_s (Int64.to_int @@ Files.Store.Info.date info)
  in
  let info =
    let open I in
    string A.(fg lightwhite ++ st bold) "Author:"
    <-> string A.(fg lightwhite ++ st bold) "Message:"
    <-> string A.(fg lightwhite ++ st bold) "Date:"
    <|> void 1 0
    <|> (string A.(fg lightwhite ++ st bold) (Files.Store.Info.author info)
        <-> string A.(fg lightwhite ++ st bold) (Files.Store.Info.message info)
        <-> strf
              ~attr:A.(fg lightwhite ++ st bold)
              "%a" (Ptime.pp_human ()) date)
  in
  let open I in
  let img = node_txt <-> (void 2 0 <|> node) <-> void 0 1 <-> parents_txt in
  ( img
    <-> (void 2 0 <|> parents)
    <-> void 0 1
    <-> info_txt
    <-> (void 2 0 <|> info),
    List.append
      (List.map (fun b -> Button.pad b 2 1) node_button)
      (List.map
         (fun b -> Button.pad b 2 (I.height img))
         (List.flatten parents_buttons)) )

let show_inode c (inode : Files.Inode.compress) =
  let open I in
  let addr_show (addr : Files.Inode.Compress.address) =
    match addr with
    | Offset addr ->
        let hit_or_miss =
          List.find_opt (fun (_, _, off) -> Int63.equal addr off) c.idxs
        in
        let img =
          match hit_or_miss with
          | None ->
              I.strf
                ~attr:A.(fg lightwhite ++ st bold)
                "Dangling entry (off %a)" Int63.pp addr
          | Some (idx, _, off_pack) ->
              let content = get_entry c off_pack in
              let open I in
              let color, text =
                match content.kind with
                | Commit_v1 | Commit_v2 -> (A.red, "Commit")
                | Dangling_parent_commit -> (A.magenta, "Dangling commit")
                | Contents -> (A.lightblue, "Contents")
                | Inode_v1_unstable | Inode_v1_stable | Inode_v2_root
                | Inode_v2_nonroot ->
                    (A.green, "Inode")
              in
              I.strf ~attr:A.(fg lightwhite ++ st bold) "Entry %d (" idx
              <|> I.string A.(fg color ++ st bold) text
              <|> I.strf
                    ~attr:A.(fg lightwhite ++ st bold)
                    ", off %a)" Int63.pp addr
        in

        ( img,
          [
            Button.
              {
                x = 0;
                y = 0;
                w = I.width img;
                h = 1;
                f = (fun c -> reload_context_with_off c addr);
              };
          ] )
    | Hash _hash ->
        (I.string A.(fg lightwhite ++ st bold) "Hash <should not happen>", [])
  in
  let name (n : Files.Inode.Compress.name) =
    match n with
    | Indirect dict_key ->
        let key = List.nth_opt c.dict dict_key in
        strf
          ~attr:A.(fg lightwhite ++ st bold)
          "Indirect key: \'%a\' (%d)" (Fmt.option Fmt.string) key dict_key
    | Direct step ->
        strf ~attr:A.(fg lightwhite ++ st bold) "Direct key: %s" step
  in
  let value i (v : Files.Inode.Compress.value) =
    let v, v_buttons =
      match v with
      | Contents (n, addr, ()) ->
          let content, content_button = addr_show addr in
          let img1 = string A.(fg lightred ++ st bold) "Contents:" in
          let img2 = name n in
          ( img1 <-> (void 2 0 <|> (img2 <-> content)),
            List.map
              (fun b -> Button.pad b 2 (I.height img1 + I.height img2))
              content_button )
      | Node (n, addr) ->
          let node, node_button = addr_show addr in
          let img1 = string A.(fg lightred ++ st bold) "Node:" in
          let img2 = name n in
          ( img1 <-> (void 2 0 <|> (img2 <-> node)),
            List.map
              (fun b -> Button.pad b 2 (I.height img1 + I.height img2))
              node_button )
    in
    let img = strf ~attr:A.(fg lightred ++ st bold) "Value %d:" i in
    ( img <-> (void 2 0 <|> v),
      List.map (fun b -> Button.pad b 2 (I.height img)) v_buttons )
  in
  let ptr i (p : Files.Inode.Compress.ptr) =
    let ptr, ptr_button = addr_show p.hash in
    let img = strf ~attr:A.(fg lightred ++ st bold) "Ptr %d:" i <|> void 2 0 in
    (img <|> ptr, List.map (fun b -> Button.pad b (I.width img) i) ptr_button)
  in
  let tree (t : Files.Inode.Compress.tree) =
    let t_img, t_buttons = List.split (List.mapi ptr t.entries) in
    let img =
      string A.(fg lightred ++ st bold) "Tree:"
      <-> (void 2 0
          <|> strf ~attr:A.(fg lightwhite ++ st bold) "Depth: %d" t.depth)
    in
    ( img <-> vcat t_img,
      List.map (fun b -> Button.pad b 0 (I.height img)) (List.flatten t_buttons)
    )
  in
  let v (tv : Files.Inode.Compress.v) s =
    let tv, tv_buttons =
      match tv with
      | Values l ->
          let v, v_buttons = List.split (List.mapi value l) in
          let _, v_buttons =
            List.fold_left2
              (fun (i, acc) img b ->
                (i + I.height img, List.map (fun b -> Button.pad b 0 i) b :: acc))
              (0, []) v v_buttons
          in
          (vcat v, List.flatten v_buttons)
      | Tree t -> tree t
    in
    let img =
      string A.(fg lightred ++ st bold) "Tagged:"
      <-> (void 2 0 <|> string A.(fg lightwhite ++ st bold) s)
      <-> void 0 1
    in
    (img <-> tv, List.map (fun b -> Button.pad b 0 (I.height img)) tv_buttons)
  in
  match inode.tv with
  | V0_stable tv -> v tv "Stable"
  | V0_unstable tv -> v tv "Unstable"
  | V1_root tv -> v tv.v "Root"
  | V1_nonroot tv -> v tv.v "Non root"

let kind_color (kind : Kind.t) =
  match kind with
  | Commit_v1 | Commit_v2 -> A.red
  | Dangling_parent_commit -> A.magenta
  | Contents -> A.lightblue
  | Inode_v1_unstable | Inode_v1_stable | Inode_v2_root | Inode_v2_nonroot ->
      A.green

let show_entry_content ~x_off ~y_off c =
  let open I in
  let hash =
    I.string A.(fg lightred ++ st bold) "Hash:"
    <-> (void 2 0 <|> I.string A.(fg lightwhite ++ st bold) c.entry_content.hash)
  in
  let kind =
    I.string A.(fg lightred ++ st bold) "Kind:"
    <-> (void 2 0
        <|> I.strf
              ~attr:A.(fg (kind_color c.entry_content.kind) ++ st bold)
              "%a" Kind.pp c.entry_content.kind)
  in
  match c.entry_content.kind with
  | Inode_v2_root | Inode_v2_nonroot ->
      let decoded = I.string A.(fg lightred ++ st bold) "Decoded:" in
      let inode, inode_buttons =
        show_inode c
        @@ Files.Inode.decode_bin_compress c.entry_content.contents (ref 0)
      in
      let hex = I.string A.(fg lightred ++ st bold) "Hexdump:" in
      let entry_header = Files.Hash.hash_size + 1 in
      let contents_len =
        String.length c.entry_content.contents - entry_header
      in
      let contents =
        String.sub c.entry_content.contents entry_header contents_len
      in
      let contents = Hex.hexdump_s @@ Hex.of_string contents in
      let contents = String.split_on_char '\n' contents in
      let entry_hexdump =
        I.vcat
        @@ List.map
             (fun s ->
               let s = Printf.sprintf "%S" s in
               I.string A.(fg lightwhite ++ st bold) s)
             contents
      in
      let img = hash <-> void 0 1 <-> kind <-> void 0 1 <-> decoded in
      ( img
        <-> (void 2 0 <|> inode)
        <-> void 0 1
        <-> hex
        <-> (void 2 0 <|> entry_hexdump)
        |> I.pad ~l:x_off ~t:y_off,
        List.map
          (fun b -> Button.pad b (x_off + 2) (y_off + I.height img))
          inode_buttons )
  | Commit_v2 | Dangling_parent_commit ->
      let open I in
      let entry_header = Files.Hash.hash_size + 2 in
      let contents_len =
        String.length c.entry_content.contents - entry_header
      in
      let contents =
        String.sub c.entry_content.contents entry_header contents_len
      in
      let commit, commit_button =
        show_commit c @@ Files.Commit.decode_bin_compress contents (ref 0)
      in
      let decoded = I.string A.(fg lightred ++ st bold) "Decoded:" in
      let hex = I.string A.(fg lightred ++ st bold) "Hexdump:" in
      let contents = Hex.hexdump_s @@ Hex.of_string contents in
      let contents = String.split_on_char '\n' contents in
      let entry_hexdump =
        I.vcat
        @@ List.map
             (fun s ->
               let s = Printf.sprintf "%S" s in
               I.string A.(fg lightwhite ++ st bold) s)
             contents
      in
      let img = hash <-> void 0 1 <-> kind <-> void 0 1 <-> decoded in
      ( img
        <-> (void 2 0 <|> commit)
        <-> void 0 1
        <-> hex
        <-> (void 2 0 <|> entry_hexdump)
        |> I.pad ~l:x_off ~t:y_off,
        List.map
          (fun b -> Button.pad b (x_off + 2) (y_off + I.height img))
          commit_button )
  | _ ->
      let entry_header = Files.Hash.hash_size + 1 in
      let contents_len =
        String.length c.entry_content.contents - entry_header
      in
      let contents =
        String.sub c.entry_content.contents entry_header contents_len
      in
      let decoded = I.string A.(fg lightred ++ st bold) "Decoded:" in
      let entry_decoded = I.string A.(fg lightwhite ++ st bold) "n/a" in
      let hex = I.string A.(fg lightred ++ st bold) "Hexdump:" in
      let contents = Hex.hexdump_s @@ Hex.of_string contents in
      let contents = String.split_on_char '\n' contents in
      let entry_hexdump =
        I.vcat
        @@ List.map
             (fun s ->
               let s = Printf.sprintf "%S" s in
               I.string A.(fg lightwhite ++ st bold) s)
             contents
      in
      ( hash
        <-> void 0 1
        <-> kind
        <-> void 0 1
        <-> decoded
        <-> (void 2 0 <|> entry_decoded)
        <-> void 0 1
        <-> hex
        <-> (void 2 0 <|> entry_hexdump)
        |> I.pad ~l:x_off ~t:y_off,
        [] )

let entry_pos c l t =
  let open I in
  string A.(fg lightyellow ++ st bold) "Entry:"
  <|> void 1 0
  <|> strf ~attr:A.(fg lightwhite ++ st bold) "%d/%d" c.entry (c.max_entry - 1)
  </> void 30 0
  <|> string A.(fg lightyellow ++ st bold) "Offset:"
  <|> void 1 0
  <|> strf
        ~attr:A.(fg lightwhite ++ st bold)
        "%a/%a" Int63.pp c.entry_content.off Int63.pp (Int63.pred c.max_offset)
  |> pad ~l ~t

let rec loop t c =
  let buttons = Menu.b c in
  let _, _, tooltip, move = buttons.(c.y).(c.x) in
  let menu_text = Menu.buttons buttons ~x_off:1 ~y_off:1 c.x c.y in
  let menu_box = menu_box (I.height menu_text - 1) (I.width menu_text - 2) in
  let tooltip =
    I.string A.(fg lightwhite ++ st bold) tooltip |> I.pad ~l:2 ~t:6
  in
  let position_text = position_text c move in
  let position_box =
    position_box (I.height menu_text + 1) (I.width position_text - 2)
  in
  let entries, entries_buttons = show_entry_content ~x_off:2 ~y_off:10 c in
  let l =
    [
      menu_text;
      tooltip;
      menu_box;
      position_text;
      position_box;
      entry_pos c 2 8;
      entries;
    ]
  in
  let b = I.zcat l in
  Term.image t b;
  match Term.event t with
  | `End | `Key (`Escape, []) | `Key (`ASCII 'C', [ `Ctrl ]) -> ()
  | `Key (`Arrow d, _) ->
      Menu.move buttons c d;
      loop t c
  | `Key (`Enter, _) ->
      let _, f, _, _ = buttons.(c.y).(c.x) in
      f c;
      loop t c
  | `Mouse (`Press _, pos, _) ->
      let l = List.filter_map (Button.on_press pos) entries_buttons in
      List.iter (fun f -> f c) l;
      loop t c
  | _ -> loop t c

let main store_path info_last_path info_next_path index_path =
  let conf = Irmin_pack.Conf.init store_path in
  let fm = Files.File_manager.open_ro conf |> Files.Errs.raise_if_error in
  let dispatcher = Files.Dispatcher.v fm |> Files.Errs.raise_if_error in
  let pl = Files.File_manager.Control.payload (Files.File_manager.control fm) in
  let max_offset =
    (* TODO: Rename [pl.suffix_end_poff] to [suffix_length] *)
    match pl.status with
    | From_v1_v2_post_upgrade _ | No_gc_yet | Used_non_minimal_indexing_strategy
      ->
        pl.suffix_end_poff
    | Gced x -> Int63.add x.suffix_start_offset pl.suffix_end_poff
    | T1 | T2 | T3 | T4 | T5 | T6 | T7 | T8 | T9 | T10 | T11 | T12 | T13 | T14
    | T15 ->
        assert false
  in

  let dict = Files.File_manager.dict fm in
  let dict = Files.load_dict dict buffer in
  let info_last_fd =
    Unix.openfile info_last_path Unix.[ O_RDONLY; O_CLOEXEC ] 0o644
  in
  let info_next_fd =
    Unix.openfile info_next_path Unix.[ O_RDONLY; O_CLOEXEC ] 0o644
  in
  let idx_fd = Unix.openfile index_path Unix.[ O_RDONLY; O_CLOEXEC ] 0o644 in
  (* let max_offset = Files.File_manager.Suffix.end_offset suffix in *)
  let max_entry, idxs = load_idxs idx_fd in
  Unix.close idx_fd;
  let entry, off_info, off_pack = List.nth idxs 0 in
  let entry_ctx = load_entry info_last_fd info_next_fd off_info in
  let entry_content =
    Obj.magic "TODO: cyclical deps between entry_content and context"
  in
  let context =
    {
      info_last_fd;
      info_next_fd;
      idxs;
      fm;
      dispatcher;
      dict;
      max_entry;
      max_offset;
      x = 3;
      y = 0;
      entry;
      entry_ctx;
      entry_content;
    }
  in
  context.entry_content <- get_entry context off_pack;
  loop (Term.create ()) context;
  Unix.close info_last_fd;
  Unix.close info_next_fd
