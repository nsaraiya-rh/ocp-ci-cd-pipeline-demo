# Frontend image — nginx serving the static page in this folder.
# Built by CI (Kaniko) on every push; the built tag flows into gitops/overlays/dev
# then, on merge, into gitops/overlays/prod. Unprivileged nginx (uid 101, port 8080).
FROM docker.io/nginxinc/nginx-unprivileged:1.25-alpine
COPY index.html /usr/share/nginx/html/index.html
EXPOSE 8080
