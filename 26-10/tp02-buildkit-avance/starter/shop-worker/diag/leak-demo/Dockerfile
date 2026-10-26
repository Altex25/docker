# Même mécanisme que le Dockerfile d'origine (ARG lu par pip), sans dépendre du registre interne.
FROM python:3.12-slim
ARG PIP_INDEX_URL
RUN pip config --global set global.index-url "$PIP_INDEX_URL"
RUN rm /etc/pip.conf
