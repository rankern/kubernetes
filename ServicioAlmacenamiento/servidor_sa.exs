Code.require_file("#{__DIR__}/cliente_gv.exs")

defmodule ServidorSA do
    
    # estado del servidor            
    defstruct base_datos: %{},
                lista_op_realizadas: [],
                ultima_vista: %{num_vista: 0, primario: :undefined, copia: :undefined}, 
                vista_validada: false,
                partido: 0,
                soy: :espera  #:primario  #:copia, 


    @intervalo_latido 50
    @tiempo_espera_de_respuesta 40

    @doc """
        Obtener el hash de un string Elixir
            - Necesario pasar, previamente,  a formato string Erlang
         - Devuelve entero
    """
    def hash(string_concatenado) do
        String.to_charlist(string_concatenado) |> :erlang.phash2
    end

    @doc """
        Poner en marcha el servidor para gestión de vistas
        Devolver atomo que referencia al nuevo nodo Elixir
    """
    @spec startNodo(String.t, String.t) :: node
    def startNodo(nombre, maquina) do
                                         # fichero en curso
        NodoRemoto.start(nombre, maquina, __ENV__.file)
    end

    @doc """
        Poner en marcha servicio trás esperar al pleno funcionamiento del nodo
    """
    @spec startService(node, node) :: pid
    def startService(nodoSA, nodo_servidor_gv) do
        NodoRemoto.esperaNodoOperativo(nodoSA, __MODULE__)
        
        # Poner en marcha el código del gestor de vistas
        Node.spawn(nodoSA, __MODULE__, :init_sa, [nodo_servidor_gv])
   end

    #------------------- Funciones privadas -----------------------------

    def init_sa(nodo_servidor_gv) do
        Process.register(self(), :servidor_sa)
    #------------- VUESTRO CODIGO DE INICIALIZACION AQUI..........

        spawn(__MODULE__, :timing, [self()]) # otro proceso concurrente
        # Poner estado inicial
        bucle_recepcion_principal(%ServidorSA{}, nodo_servidor_gv) 
    end

    #Funcion que genera un periodo para gestionar
    #desde el hilo principal el envio de latidos
    def timing(pid_principal) do
        send(pid_principal, :procesa_latidos)
        Process.sleep(@intervalo_latido)
        timing(pid_principal)
    end

    defp bucle_recepcion_principal(estado, nodo_servidor_gv) do
        primario = estado.ultima_vista.primario
        estado = receive do

                #realizar latido
                {:particionar, n} -> %{estado | partido: n}
                :mostar_operaciones -> IO.inspect(estado.lista_op_realizadas, label: to_string(estado.soy) <> " OPERACIONES REALIZADAS")
                                        estado
                {:dormir, msecs} -> Process.sleep(msecs)
                                    estado
                :procesa_latidos -> if estado.partido == 0 do
                                        gestionarLatidos(estado, nodo_servidor_gv)
                                        estado
                                    else
                                        %{estado | partido: estado.partido - 1}
                                    end
                                    
                #recibir respuesta de latido y gestionar la vista que se nos ha enviado
                {:vista_tentativa, vista, encontrado} -> gestionarVista(estado, vista, encontrado)

                #recibir del primario que tenemos guardado en nuestro estado como primario la orden de realizar
                #la copia de la base de datos
                {:copiarBD, nuevaBD, opRealizadas, prim} -> gestionarCopiaBD(estado, nuevaBD, opRealizadas, prim)
                                                                                                             
                # Solicitudes de lectura y escritura
                # de clientes del servicio de almacenamiento
                {op, param, nodo_origen, idOp}  -> #IO.puts "Recepcion de operacion"
                                                    gestionarOperacion(estado, op, param, nodo_origen, idOp)

                {:opCopia, emisor ,contenido} -> if emisor == estado.ultima_vista.primario and estado.soy == :copia do
                                                        gestionesCopia(emisor, estado, contenido)
                                                    else
                                                        #Si no es mi primario o no soy copia, ignorar
                                                        estado
                                                    end
                cosa -> testPruebas(estado, cosa)
                end
        bucle_recepcion_principal(estado, nodo_servidor_gv)
    end
    


    #--------- Otras funciones privadas que necesiteis .......
    #Realiza la gestion de las operaciones relacionadas con lectura y escritura
    #de la base de datos, como leer y escribir, por parte de los clientes del
    #sistema gestor de almacenamiento
    def escrituraOp(estado, param, nodo_origen, idOp) do
        use_hash = elem(param, 2)
        nuevo_valor = elem(param, 1)
        clave = elem(param, 0)
        #param[2] = hay que hacer hash o no
        #comprobamos si hay que hacer la escritura mediante hash

        {aEscribir, aDevolver} = cond do
            use_hash and Map.has_key?(estado.base_datos, clave) ->  
                                    {hash(estado.base_datos[clave] <> nuevo_valor),estado.base_datos[clave]}
            use_hash -> {hash(nuevo_valor), ""}
            true -> {nuevo_valor, nuevo_valor}
        end
        #IO.puts("aEscribir: " <> to_string(aEscribir) <> " " <> to_string(aDevolver))
        nuevoEstado = if enviarOperacionCopia(estado, estado.ultima_vista.copia, {:peticionEscritura, idOp, clave, aEscribir, aDevolver, nodo_origen}) do
                    escrituraEnBase(estado, clave, nuevo_valor, aDevolver, idOp, nodo_origen)
            else    #TODO:: SI fallo en copia, pendiente????
                estado
            end
        send({:cliente_sa, nodo_origen}, {:resultado, aDevolver})
        nuevoEstado
    end


    def lecturaOP(estado, clave, nodo_origen, idOp) do
         #Comprobamos si el par clave-valor existe en la base de datos
            almacenar = if Map.has_key?(estado.base_datos, clave) do
                    estado.base_datos[clave]
                else
                    ""
                end
               # IO.inspect(clave, label: "clave pedida")
               # IO.inspect(almacenar, label: "devolver a cliente ")
            if enviarOperacionCopia(estado, estado.ultima_vista.copia, {:realizarLecutra, idOp, almacenar, nodo_origen}) do
                       send({:cliente_sa, nodo_origen}, {:resultado, almacenar})
                       anyadirOp(estado, almacenar, idOp, nodo_origen)
                else
                    #si fallo en copia, que vuelva ha enviar?? se envia sin mas?
                    estado
                end
    end


    def nuevaOperacion(nodo_origen, idOp, hd_operacion, lista) do
        case hd_operacion do
            {valor, ^idOp, ^nodo_origen} -> valor
            _ -> if lista != [] do 
                    nuevaOperacion(nodo_origen, idOp, hd(lista), tl(lista))
                else
                    :noExiste
                end
        end
    end

    def nuevaOperacion(nodo_origen, idOp, lista) do
        if lista != [] do 
            nuevaOperacion(nodo_origen, idOp, hd(lista), tl(lista))
        else
            :noExiste
        end
    end

    #devuelve un estado con resultado de haber realizado op o devuelve mismo estado
    defp gestionarOperacion(estado, op, param, nodo_origen, idOp) do
        #Dividimos la tupla para mayor legibilidad del codigo
        #Si nos ha llegado una operacion de escritura
        if estado.soy == :primario and estado.vista_validada do
            case nuevaOperacion(nodo_origen, idOp, estado.lista_op_realizadas) do

            :noExiste ->
                if op == :escribe_generico do
                    escrituraOp(estado, param, nodo_origen, idOp)
                    
                else
                    lecturaOP(estado, param, nodo_origen, idOp)
                end
            valor ->
                    if enviarOperacionCopia(estado, estado.ultima_vista.copia, :ping) do
                        send({:cliente_sa, nodo_origen}, {:resultado, valor})
                    end
                    estado
            end
        else
            send({:cliente_sa, nodo_origen}, {:resultado, :no_soy_primario_valido})
            estado
        end
    end


    #Envia a la copia la base de datos actual y espera confirmacion
    def enviarBD(estado, base_datos, lista_op_realizadas, copia) do
        if estado.partido <= 0 do
            #Solo se envia si no esta en una partido aparte
            send({:servidor_sa, copia}, {:copiarBD, base_datos, lista_op_realizadas, Node.self()})
        end
        receive do
            :copiaOK -> true
        after #la copia ha hecho timeout
            @tiempo_espera_de_respuesta -> false
        end 
    end


    #Copia = direccion copia
    #contenido = tupla de elementos a enviar
    def enviarOperacionCopia(estado, copia, contenido) do
        if estado.partido <= 0 do
            send({:servidor_sa, copia}, {:opCopia, Node.self ,contenido})
        end
        receive do
            :copiaOK -> true
        after
            @tiempo_espera_de_respuesta -> false
        end
    end

    def escrituraEnBase(estado, clave, valor, aDevolver, idOp, nodo_origen) do
        %{estado | base_datos: Map.put(estado.base_datos, clave, valor), lista_op_realizadas: estado.lista_op_realizadas ++ [{aDevolver, idOp, nodo_origen}]}
    end

    def anyadirOp(estado, valor,idOp, nodo_origen) do
        %{estado | lista_op_realizadas: estado.lista_op_realizadas ++ [{valor, idOp, nodo_origen}]}
    end

    def gestionesCopia(primario, estado, contenido) do
        nuevo_estado = case contenido do
            {:peticionHash, id, clave, valor, resultado, nodo_origen} -> escrituraEnBase(estado, clave, valor, resultado, id, nodo_origen)
            {:peticionEscritura, id, clave, valor, resultado, nodo_origen} -># IO.puts "peticion escritura recibida"
                                    escrituraEnBase(estado, clave, valor, resultado, id, nodo_origen)
            {:realizarLecutra, id, dato, nodo_origen} ->  anyadirOp(estado, dato, id, nodo_origen)
            :ping -> estado
            _ -> IO.inspect(contenido, label: "Error en contenido")
                estado
                                                    
        end
        if estado.partido <= 0 do
            send({:servidor_sa, primario}, :copiaOK)
        end
        nuevo_estado
    end


     #Realiza la gestion o envio de los latidos pertinentes al Servidor Gestor de Vistas
    defp gestionarLatidos(estado, nodo_servidor_gv) do
       # IO.puts "gestionar latidos"
        if estado.vista_validada or estado.soy != :primario do
            send({:servidor_gv, nodo_servidor_gv}, {:latido, estado.ultima_vista.num_vista, Node.self()})
        else
            #Estados sin confirmar la vista tentativa por parte del primario
            case estado.ultima_vista.num_vista do
                #Estado inicial, incorporacion al sistema
                0 -> send({:servidor_gv, nodo_servidor_gv},{:latido, 0, Node.self()})
                #Estado con un primario y ninguna copia
                1 -> send({:servidor_gv, nodo_servidor_gv},{:latido, -1, Node.self()})
                #Estado generico donde enviamos al servidor gestor de vistas nuestro numero de vista menos 1
                _ -> send({:servidor_gv, nodo_servidor_gv},
                        {:latido, estado.ultima_vista.num_vista - 1, Node.self()})
            end
        end
        #esperar respuesta del servidor gestor de vistas en el bucle principal
    end

    #Funcion que gestiona la nueva vista recibida del servidor gestor de vistas tras haber
    #enviado un latido
    def gestionarVista(estado, vista, valido) do
        #Si es la misma vista, se actualiza siempre vista_validada
        es = if estado.ultima_vista == vista and valido do
             %{estado | vista_validada: valido}
        else
            #Gestion de los distintos casos cuando ha cambiado el estado
            case estado.soy do
                #Si nosotros somos el primario en la vista tentativa recibida
                :primario ->   if vista.primario != Node.self do
                                    IO.inspect({vista}, label: "nuevo primario generado")
                                    %{estado | ultima_vista:
                                                     %{estado.ultima_vista | primario: vista.primario, 
                                                                copia: vista.copia, num_vista: 0}, 
                                            soy: :espera, vista_validada: valido}
                                    #Enviar 0
                                else
                                    #sigo siendo primario -> copia ha cambiado
                                    %{estado | ultima_vista: vista, 
                                        vista_validada: enviarBD(estado, estado.base_datos, estado.lista_op_realizadas, vista.copia)}
                                end
                #En caso de que hasta ahora fueramos copia
                :copia ->   if vista.primario == Node.self() do #Si en la nueva vista antigua copia es primario,
                                #enviar a la nueva copia la base de datos
                                 %{estado | soy: :primario, ultima_vista: vista, 
                                        vista_validada: enviarBD(estado, estado.base_datos, estado.lista_op_realizadas, vista.copia)}
                            else
                                if vista.copia != Node.self() do #TODO:ver si en este caso se deberia mandar un 0 al servidor
                                    %{estado | ultima_vista:
                                                     %{estado.ultima_vista | primario: vista.primario, 
                                                                copia: vista.copia, num_vista: 0},
                                                vista_validada: valido, soy: :espera}
                                    #enviar 0
                                else
                                    %{estado | ultima_vista: vista, vista_validada: valido} 
                                end
                            end
                :espera ->  cond do
                                vista.primario == Node.self() and vista.copia == :undefined -> #Solo en Estado Inicial!
                                            %{estado | ultima_vista: vista, vista_validada: false, soy: :primario} 
                                vista.primario == Node.self() and vista.copia != :undefined -> IO.puts "Este estado no deberia haber ocurrido"
                                vista.copia == Node.self() -> %{estado | ultima_vista: vista, vista_validada: valido, soy: :copia}
                                true -> %{estado | ultima_vista: vista, vista_validada: valido}
                            end
                _ -> IO.puts "Error en el campo del estado 'Soy'"
            end
        end
        if es.partido >0 do
            IO.inspect(es.ultima_vista)
        end
        es
    end
    
    def gestionarCopiaBD(estado, nuevaBD, opRealizadas, prim) do
        if estado.soy == :copia and prim == estado.ultima_vista.primario do
            IO.inspect(estado.ultima_vista, label: "Ultima vista al realizar copia BD")
            send({:servidor_sa, estado.ultima_vista.primario}, :copiaOK)
            %{estado | base_datos: nuevaBD, lista_op_realizadas: opRealizadas}
        else
            estado
        end
    end



    def testPruebas(estado, cosa) do
        txt = case estado.soy do
        :primario -> "Soy primario y me ha llegado "
        :copia -> "Soy copia y me ha llegado"
        _ -> "Estoy  a la espera y me ha llegado"
        end

        IO.inspect(cosa, label: txt)
        estado
    end


end

