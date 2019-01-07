defmodule A do

    def loop do
    
        receive do
            {:dime, pid} -> send pid, "recibido"
            {otracosa, pid} -> send pid, otracosa
        end
        
        loop
    end
end

Process.register self, :p

A.loop
