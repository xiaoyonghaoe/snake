# Disposable test image; not an application dependency or production server.
FROM ubuntu:24.04
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends bash zsh fish coreutils && rm -rf /var/lib/apt/lists/*
CMD ["/bin/bash"]
