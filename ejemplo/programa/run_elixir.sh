elixir --name e@$1 --cookie palabrasecreta \
      --erl  \
       '-kernel inet_dist_listen_min 32000 -kernel inet_dist_listen_max 32000' \
      /programa/prueba.exs
