docker buildx build --platform linux/amd64,linux/arm64 --no-cache -t kong-gubernated:3.11.1 . 
docker buildx build --platform linux/amd64,linux/arm64 --no-cache -t sal1103/kong-gubernated:3.11.1 . 
docker push sal1103/kong-gubernated:3.11.1