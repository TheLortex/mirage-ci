module Git = Current_git
module Docker = Current_docker.Default
open Current.Syntax
open Mirage_ci_lib

type mode = UniverseEdge | MirageEdge | Released

type toolchain = Host | Freestanding

let pp_toolchain () = function Host -> "" | Freestanding -> "-x freestanding"

let get_monorepo_library =
  let pp_lib f (project : Universe.Project.t) =
    Fmt.pf f "@[%a @,@]" Fmt.(list ~sep:(fun f () -> Fmt.pf f " ") string) project.opam
  in
  Fmt.str
    {|
  (library
   (name monorepo)
   (public_name monorepo)
   (libraries %a)
  )
  |}
    (Fmt.list pp_lib)

let v ~(platform : Platform.t) ~roots ~mode ?(src = Current.return []) ?(toolchain = Host) ~repos
    ~lock () =
  let open Obuilder_spec in
  let base =
    let+ repos = repos in
    Platform.spec platform.system |> Spec.add (Setup.add_repositories repos)
  in
  let base =
    let+ base = base in
    match toolchain with
    | Host -> base
    | Freestanding ->
        Spec.add (Setup.install_tools [ "ocaml-freestanding"; "ocamlfind.1.8.1" ]) base
  in
  let name_of_toolchain = match toolchain with Host -> "host" | Freestanding -> "freestanding" in
  let name_of_mode =
    match mode with
    | UniverseEdge -> "universe-edge"
    | MirageEdge -> "mirage-edge"
    | Released -> "released"
  in
  let spec =
    match mode with
    | MirageEdge | Released -> Monorepo.spec ~base ~lock ()
    | UniverseEdge ->
        let+ base = base in
        base |> Spec.add (Setup.install_tools [ "dune" ])
  in
  let spec =
    match mode with
    | Released -> spec
    | MirageEdge ->
        let+ spec = spec in
        Spec.add
          [
            workdir "/src/duniverse";
            run "sudo chown opam:opam /src/duniverse";
            copy [ "." ] ~dst:"/src/duniverse/";
            workdir "/src";
          ]
          spec
    | UniverseEdge ->
        let+ spec = spec in
        Spec.add
          [
            workdir "/src/duniverse";
            run "sudo chown opam:opam /src/duniverse";
            copy [ "." ] ~dst:"/src/duniverse/";
            run "touch dune && mv dune dune_";
            run "echo '(vendored_dirs *)' >> dune";
            workdir "/src";
          ]
          spec
  in
  let dune_build =
    let+ spec = spec in
    let open Obuilder_spec in
    Spec.add
      [
        run "echo '%s' >> dune" (get_monorepo_library roots);
        run "touch monorepo.opam; touch monorepo.ml";
        run "find . -type f -name 'dune-project' -exec sed 's/(strict_package_deps)//g' -i {} \\;";
        (* Dune issue with strict_package_deps *)
        run "opam exec -- dune build --profile release --debug-dependency-path %a" pp_toolchain
          toolchain;
        run "du -sh _build/";
      ]
      spec
  in
  let cache_hint = "mirage-ci-monorepo-" ^ Fmt.str "%a" Platform.pp_system platform.system in
  let cluster = Current_ocluster.v (Current_ocluster.Connection.create Config.cap) in
  Current_ocluster.build_obuilder
    ~label:(name_of_toolchain ^ "-" ^ name_of_mode)
    ~cache_hint cluster ~pool:(Platform.ocluster_pool platform) ~src
    (dune_build |> Config.to_ocluster_spec)

let lock ~(system : Platform.system) ~value ~monorepo ~repos (projects : Universe.Project.t list) =
  Current.with_context repos (fun () ->
      let configuration =
        Monorepo.opam_file
          ~ocaml_version:(Fmt.str "%a" Platform.pp_exact_ocaml system.ocaml)
          projects
      in
      Monorepo.lock ~value ~repos ~opam:(Current.return configuration) monorepo)

let universe_edge ~platform ~remote_pull ~remote_push ~roots ~repos ~lock =
  let src =
    let+ src =
      Mirage_ci_lib.Monorepo_git_push.v ~remote_pull ~remote_push ~branch:"universe-edge"
        (Monorepo_lock.commits lock)
    in
    [ src ]
  in
  [
    ( "universe-edge-freestanding",
      v ~platform ~src ~roots ~mode:UniverseEdge ~toolchain:Freestanding ~repos ~lock () );
    ("universe-edge-host", v ~platform ~src ~roots ~mode:UniverseEdge ~repos ~lock ());
  ]
  |> Current.all_labelled

let mirage_edge ~platform ~remote_pull ~remote_push ~roots ~repos ~lock =
  let filter (project : Monorepo_lock.project) =
    List.exists
      (fun (prj : Universe.Project.t) ->
        Astring.String.find_sub ~sub:prj.repo project.repo |> Option.is_some)
      roots
  in
  let src =
    let+ src =
      Mirage_ci_lib.Monorepo_git_push.v ~remote_pull ~remote_push ~branch:"mirage-edge"
        (Monorepo_lock.commits ~filter lock)
    in
    [ src ]
  in
  [
    ( "mirage-edge-freestanding",
      v ~platform ~src ~roots ~mode:MirageEdge ~toolchain:Freestanding ~repos ~lock () );
    ("mirage-edge-host", v ~platform ~src ~roots ~mode:MirageEdge ~repos ~lock ());
  ]
  |> Current.all_labelled

let released ~platform ~roots ~repos ~lock =
  [
    ( "released-freestanding",
      v ~platform ~roots ~mode:Released ~toolchain:Freestanding ~repos ~lock () );
    ("released-host", v ~platform ~roots ~mode:Released ~repos ~lock ());
  ]
  |> Current.all_labelled
