kubectl delete statefulset raft
kubectl delete service elixir
kubectl delete configmap cm-elixir
kubectl create configmap cm-elixir --from-file=./programa
kubectl create -f statefulset_elixir.yaml
