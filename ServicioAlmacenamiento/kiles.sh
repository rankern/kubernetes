#!/bin/bash

pkill epmd
pkill beam*
pkill elixir
pkill erlang
pkill erl; pkill erl; pkill erl; pkill epmd
./validar_servicio_almacenamiento.sh