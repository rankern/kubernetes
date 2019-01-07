kubectl delete pod e1
kubectl delete pod e2
kubectl delete service elixir
kubectl delete configmap cm-elixir
echo "--------- Esperar unos segundos para dar tiempo que terminen Pods previos"
sleep 10
kubectl create configmap cm-elixir --from-file=./programa
kubectl create -f pods_elixir.yaml
