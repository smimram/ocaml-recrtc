let static_root = "static"

let () =
  Dream.run
  @@ Dream.logger
  @@ Dream.router
       [
         Dream.get "/" (fun request ->
             Dream.from_filesystem static_root "index.html" request);
         Dream.get "/**" (Dream.static static_root);
       ]
