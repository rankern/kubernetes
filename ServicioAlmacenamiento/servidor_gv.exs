require IEx # Para utilizar IEx.pry

defmodule ServidorGV do
    @moduledoc """
        modulo del servicio de vistas
    """
   # Constantes
    @latidos_fallidos 4

    @intervalo_latidos 50

    # Tipo estructura de datos que guarda el estado del servidor de vistas
    # COMPLETAR  con lo campos necesarios para gestionar
    # el estado del gestor de vistas
    defstruct   vista_valida: %{num_vista: 0, primario: :undefined, copia: :undefined}, 
                vista_tentativa: %{num_vista: 0, primario: :undefined, copia: :undefined},
                lista_espera: [],
                lista_latidos: [],
                timeouts_primario: @latidos_fallidos + 1,
                timeouts_copia: @latidos_fallidos + 1,
                debug_vistas_generadas: []

    @doc """
        Acceso externo para constante de latidos fallios
    """
    def latidos_fallidos() do
        @latidos_fallidos
    end

    @doc """
        acceso externo para constante intervalo latido
    """
   def intervalo_latidos() do
       @intervalo_latidos
   end

   @doc """
        Generar un estructura de datos vista inicial
    """
    def vista_inicial() do
        %{num_vista: 0, primario: :undefined, copia: :undefined}
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
    @spec startService(node) :: boolean
    def startService(nodoElixir) do
        NodoRemoto.esperaNodoOperativo(nodoElixir, __MODULE__)
        
        # Poner en marcha el código del gestor de vistas
        Node.spawn(nodoElixir, __MODULE__, :init_sv, [])
   end

    #------------------- FUNCIONES PRIVADAS ----------------------------------

    # Estas 2 primeras deben ser defs para llamadas tipo (MODULE, funcion,[])
    def init_sv() do
        Process.register(self(), :servidor_gv)

        spawn(__MODULE__, :init_monitor, [self()]) # otro proceso concurrente

        #### VUESTRO CODIGO DE INICIALIZACION
       # #IO.inspect(%ServidorGV{}, label: "Estado inicial")
        bucle_recepcion(%ServidorGV{})
    end

    def init_monitor(pid_principal) do
        send(pid_principal, :procesa_situacion_servidores)
        Process.sleep(@intervalo_latidos)
        init_monitor(pid_principal)
    end

    #Num vista = 0 -> estado inicial, no han llegado ni un primario ni una copia iniciales
    #Num vista = 1 -> estado en el que tenemos un primario pero aun no ha llegado una copia
    #Resto de num_vistas -> caso general
    defp bucle_recepcion(estado) do
        estado = receive do
                    {:latido, n_vista_latido, nodo_emisor} ->
                      #  #IO.inspect(estado, label: "Estado actual")
                        case estado.vista_tentativa.num_vista do
                        #No existe primario ni copia
                            0 -> #IO.puts "Primer primario"
                                estadoNuevo = %{estado | vista_tentativa: %{estado.vista_tentativa 
                                        | num_vista: (estado.vista_tentativa.num_vista + 1), primario: nodo_emisor},
                                         timeouts_primario: @latidos_fallidos + 1}
                           #     #IO.inspect(estadoNuevo.vista_tentativa, label: "estado a enviar")
                                send({:servidor_sa, nodo_emisor}, {:vista_tentativa , estadoNuevo.vista_tentativa, false})
                                estadoNuevo
                        #Existe primario pero no copia
                            1 -> cond do
                                    #Latido primario
                                    nodo_emisor == estado.vista_tentativa.primario ->  #IO.puts "Es primario"
                                                send({:servidor_sa, nodo_emisor}, {:vista_tentativa , estado.vista_tentativa, false})
                                                %{estado | timeouts_primario: @latidos_fallidos + 1 }
                                    #latido nueva copia
                                    n_vista_latido == 0 -> IO.puts "se generara una nueva copia"
                                                estadoNuevo = %{estado | vista_tentativa: %{estado.vista_tentativa 
                                                                                | num_vista: (estado.vista_tentativa.num_vista + 1), 
                                                                                        copia: nodo_emisor},
                                                                    timeouts_copia: @latidos_fallidos + 1}
                                                send({:servidor_sa, nodo_emisor}, {:vista_tentativa , estadoNuevo.vista_tentativa, 
                                                        true})
                                                #IO.inspect(estadoNuevo.vista_tentativa, label: "estado Nuevo\n")
                                                %{estadoNuevo | vista_valida: estadoNuevo.vista_tentativa}
                                    true -> IO.puts "Estado vista 1, Error al recibir numero vista"
                                            estado
                                end
                            _-> cond do
                                    nodo_emisor == estado.vista_tentativa.primario ->
                                        nEstado = cond do
                                            #El primario nos envia un 0, lo que indica que ha perdido la memoria porque se ha reiniciado
                                            n_vista_latido == 0 -> IO.puts "**********>\npromocionando nuevo primario, primario caido\n<**********"
                                                            nuevoEstado = %{estado | lista_espera: estado.lista_espera ++ [nodo_emisor], 
                                                                                    lista_latidos: estado.lista_latidos ++ [nodo_emisor]}
                                                            promocionarPrimario(nuevoEstado)
                                                                    
                                                                   
                                            n_vista_latido == estado.vista_tentativa.num_vista 
                                                and estado.vista_tentativa != estado.vista_valida ->
                                                    #Si no estaba la vista validada y nos envia el mismo numero de vista que la tentativa, ha
                                                    #confirmado la vista y lo almacenamos en el estado
                                                    IO.puts "Vista Validada"
                                                    %{estado | vista_valida: estado.vista_tentativa, timeouts_primario: @latidos_fallidos + 1}

                                            true -> #IO.puts "Primario: n_vista = " <> to_string(n_vista_latido) <> "\n"
                                                    ##IO.inspect(estado.vista_valida, label: "Vista Valida")
                                                    #IO.inspect(estado.vista_tentativa, label: "Vista Tentativa")
                                                    #Nos ha llegado un latido del primario estando la vista confirmada, por lo que simplemente
                                                    #reseteamos los reintentos que le quedan para conectarse
                                                %{estado | timeouts_primario: @latidos_fallidos + 1}                    
                                        end
                                        #Enviamos al emisor la nueva vista tentativa
                                        send({:servidor_sa, nodo_emisor}, {:vista_tentativa , nEstado.vista_tentativa, 
                                                                nEstado.vista_tentativa==nEstado.vista_valida})
                                        nEstado

                                    nodo_emisor == estado.vista_tentativa.copia ->
                                       if n_vista_latido == 0 do #si la copia nos indica un reinicio
                                            IO.puts "-------\nPromocionando nueva copia, copia caida\n-----"
                                            #almacenamos en la lista de espera el nuevo nodo
                                            nuevoEstado = %{estado| lista_espera: estado.lista_espera ++ [nodo_emisor], 
                                                            lista_latidos: estado.lista_latidos ++ [nodo_emisor]}
                                            nuevoEstado = promocionarNuevaCopia(nuevoEstado)
                                            #le enviamos la vista tentativa actual
                                            send({:servidor_sa, nodo_emisor}, {:vista_tentativa , nuevoEstado.vista_tentativa, 
                                                            nuevoEstado.vista_tentativa==nuevoEstado.vista_valida})
                                            nuevoEstado
                                        else
                                            send({:servidor_sa, nodo_emisor}, {:vista_tentativa , estado.vista_tentativa, 
                                                            estado.vista_tentativa==estado.vista_valida})
                                            %{estado | timeouts_copia: @latidos_fallidos + 1}
                                        end
                                    true -> #IO.puts "Latido recibido de " <> to_string(nodo_emisor) <> " vista " <> to_string(n_vista_latido)
                                       nuevoEstado = if n_vista_latido == 0 do #si el nodo nos indica un inicio
                                                #Comprobamos que el nodo no este ya en la lista de espera, para no anyadirlo dos veces
                                                if Enum.member?(estado.lista_espera, nodo_emisor) do
                                                    %{estado | lista_latidos: [nodo_emisor] ++ estado.lista_latidos}  
                                                else
                                                    #comprobamos estado donde existe un primario, pero no existe copia porque se ha caido
                                                    #y no habia ningun nodo en espera
                                                    if estado.vista_tentativa.primario != :undefined 
                                                            and estado.vista_tentativa.copia == :undefined do
                                                        #si no hay copia definida
                                                        %{estado | vista_tentativa: %{estado.vista_tentativa | copia: nodo_emisor, 
                                                                                            num_vista: estado.vista_tentativa.num_vista + 1},
                                                                    timeouts_copia: @latidos_fallidos + 1}
                                                    else
                                                        %{estado |  lista_espera: [nodo_emisor] ++ estado.lista_espera,
                                                            lista_latidos: [nodo_emisor] ++ estado.lista_latidos}
                                                    end
                                                end
                                        else
                                            #Si no ha enviado un 0 (no acaba de iniciarse) lo metemos a la lista de latidos
                                            %{estado | lista_latidos: [nodo_emisor] ++ estado.lista_latidos}
                                        end
                                        #Realizamos ack del latido enviando la vista tentativa al nodo emisor del latido
                                        send({:servidor_sa, nodo_emisor}, {:vista_tentativa , nuevoEstado.vista_tentativa, 
                                                            nuevoEstado.vista_tentativa==nuevoEstado.vista_valida})
                                        nuevoEstado
                                end
                        end
                        
                
                    {:obten_vista, pid} -> #IO.inspect(estado, label: "Obtener vista\n")
                                    send(pid, {:vista_valida, estado.vista_valida, estado.vista_tentativa == estado.vista_valida})
                                            estado              

                    {:obten_lista_espera, pid} -> send(pid, {:lista_espera, estado.lista_espera}) #Mensaje para el test
                                                    estado

                    :procesa_situacion_servidores ->
                        estadoRestado = %{estado | timeouts_primario: estado.timeouts_primario-1,
                                   timeouts_copia: estado.timeouts_copia-1}
                        nuevoEstado = case estadoRestado.vista_tentativa.num_vista do
                            0-> estadoRestado   #Si aun no hay ningun nodo conectado
                            1->  #si estamos en el caso en que no hay copia pero si el primario
                                    if(estadoRestado.timeouts_primario== 0)do 
                                        IO.puts "fallos superados en primario en vista 1"
                                        %{estadoRestado |  debug_vistas_generadas: estadoRestado.debug_vistas_generadas ++ [estadoRestado.vista_tentativa],
                                                            vista_tentativa: vista_inicial()}
                                    else
                                        estadoRestado
                                    end
                            _ -> cond do #Caso general
                                    #Si ambos primario y copia crashean (los reintentos se han agotado)
                                    estadoRestado.timeouts_primario == 0 and estadoRestado.timeouts_copia == 0 -> #IO.inspect(estado.debug_vistas_generadas, label: "CRASHHH!!!!(Primario y copia Caidos)\n")
                                                                 esr = %{estadoRestado | vista_tentativa: %{estadoRestado.vista_tentativa | primario: :undefined, copia: :undefined}}
                                                                #IO.inspect(esr, label: "ambos caidos, nuevo estado\n")
                                                                esr
                                    estadoRestado.timeouts_primario == 0 -> IO.puts "\n*/*/*/*/*/*/*/*/\n TIMEOUT primario FAIL\n\n" #El primario ha agotado los reintento
                                                                            promocionarPrimario(estadoRestado)
                                    estadoRestado.timeouts_copia == 0 ->  IO.puts "\n*/*/*/*/*/*/*/*/\n TIMEOUT copia FAIL\n\n" #La copia ha agotado sus reintentos
                                                                            esta = promocionarNuevaCopia(estadoRestado)
                                                                            #IO.inspect(esta.debug_vistas_generadas, label: "vistas generadas\n")
                                                                            #IO.inspect(esta.vista_tentativa, label: "Nueva vista tentativa")
                                                                            esta
                                    true -> estadoRestado
                                end
                        end
                        #IO.inspect(nuevoEstado, label: "Procesar situacion servidores nuevo")
                        %{nuevoEstado | lista_latidos: []}
        end

        bucle_recepcion(estado)
    end
    
    #Funcion que se encarga de realizar la promocion de la copia a primario
    #y de llamar a la funcion promocionarNuevaCopia para promocionar a copia
    #un nodo en espera
    def promocionarPrimario(estado) do
        IO.puts "generando nuevo primario"
            #primaryOld = estado.vista_actual.primario
        #si estamos en un estado confirmado
        if estado.vista_tentativa == estado.vista_valida do
            #la copia es ahora el primario
            nuevoEstado = %{estado | vista_tentativa: %{estado.vista_tentativa 
                                        | primario: estado.vista_valida.copia, copia: :undefined}, timeouts_primario: estado.timeouts_copia}
            promocionarNuevaCopia(nuevoEstado)
        else #si no estaba el estado confirmado, algo va mal y no tenemos un estado consistente, hemos perdido informacion
            #y por tanto no podemos dar servicio
            #CRASH
            #IO.inspect(estado, label: "Ultimo estado\n")
            %{estado | vista_tentativa: %{estado.vista_tentativa | primario: :undefined}}
        end
    end

    #Funcion que se encarga de promocionar un nodo en espera a copia
    def promocionarNuevaCopia(estado) do
        IO.puts "generando nueva copia"
        if estado.vista_tentativa.primario == :undefined do
            #Si el primario es :undefined significa que ha caido sin haber confirmado, por tanto
            #indicamos el estado de error nombrando un estado undefined
            %{estado | vista_tentativa: %{estado.vista_tentativa | copia: :undefined}}
        else
            #si no hay ningun nodo en espera, entonces copia no esta definido. El primario debera esperar a que se conecte
            #un nuevo nodo al sistema
            estadoNuevo = if estado.lista_espera == [] do 
                ##IO.inspect(estado.debug_vistas_generadas, label: "CRASHHH!!!!(sin lista_espera)\n")
                #%{estado | vista_tentativa: %{estado.vista_tentativa | primario: :undefined, copia: :undefined}}
                %{estado | vista_tentativa: %{estado.vista_tentativa | copia: :undefined, num_vista: (estado.vista_tentativa.num_vista + 1)}}
            else
                if estado.lista_latidos == [] do #Si ninguno de los nodos de espera ha latido aun, pondremos como copia
                                                 #al primer nodo de la lista de espera, aunque desconozcamos si esta caido o no
                    nuevaCopia = hd(estado.lista_espera)
                    %{estado | vista_tentativa: %{estado.vista_tentativa 
                                                | num_vista: (estado.vista_tentativa.num_vista + 1), copia: nuevaCopia},
                                                lista_espera: tl(estado.lista_espera)}
                else 
                    #Por el contrario, si tenemos latidos, cogemos el ultimo nodo que haya latido
                    nuevaCopia = hd(estado.lista_latidos)
                    %{estado | vista_tentativa: %{estado.vista_tentativa 
                                                | num_vista: (estado.vista_tentativa.num_vista + 1), copia: nuevaCopia},
                                                timeouts_copia: @latidos_fallidos + 1, lista_latidos: tl(estado.lista_latidos),
                                                lista_espera: List.delete(estado.lista_espera, nuevaCopia)}
                end
            end
            #A modo de debug, metemos en las vistas generadas tanto la vista valida como la vista tentativa y devolvemos el nuevo estado
            %{ estadoNuevo | debug_vistas_generadas: estadoNuevo.debug_vistas_generadas ++ [{estadoNuevo.vista_valida, estadoNuevo.vista_tentativa}]}
        end
    end
end
