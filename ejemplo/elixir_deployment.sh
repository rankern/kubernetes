kubectl delete deploy/de
kubectl delete configmap cm-elixir
kubectl create configmap cm-elixir --from-file=./programa
kubectl create -f deploy_elixir.yaml
