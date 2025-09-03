# Start from the latest Nim image
FROM nimlang/nim:latest

# Set the working directory in the container
WORKDIR /src

# Copy the current directory contents into the container at /app
COPY . /src

# Compile the Nim application
RUN nim c -d:release -d:ssl --mm:orc --threads:off -o:/src/main src/main.nim

# Make port 8080 available to the world outside this container
EXPOSE 8080

# Run the app when the container launches
CMD ["/src/main"]