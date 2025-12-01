# Global helpers for podman-compose

pcup() {
    podman-compose up -d >/dev/null 2>&1
}

pcdown() {
    podman-compose down >/dev/null 2>&1
}