docker buildx build --platform linux/amd64,linux/arm64 -t kong-gubernated:1.0.0 . 
docker buildx build --platform linux/amd64,linux/arm64 -t sal1103/kong-gubernated:1.0.0 . 
docker buildx build --platform linux/amd64,linux/arm64 -t sal1103/kong-gubernated:latest . 
docker push sal1103/kong-gubernated:1.0.0
docker push sal1103/kong-gubernated:latest