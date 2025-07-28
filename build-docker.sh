docker buildx build --platform linux/amd64,linux/arm64 -t sal1103/kong-gubernated:1.0.1 . 
docker tag kong-gubernated:1.0.1 sal1103/kong-gubernated:latest
docker push sal1103/kong-gubernated:1.0.1
docker push sal1103/kong-gubernated:latest