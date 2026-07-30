# no build step and no devDependencies here, so multi-stage wouldn't buy much - it'd
# just copy the same node_modules/src into the same final image through an extra layer
FROM node:22-alpine

WORKDIR /app

# deps copied and installed before the source, so this layer only rebuilds on
# package*.json changes, not every source edit
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force

COPY src ./src

# alpine's node image already has a non-root "node" user, no need to make one.
# everything above got copied in as root, but the app only reads it at runtime
USER node

ENV PORT=8080
EXPOSE 8080

# /health hits the db (SELECT 1), so this catches a dead db too, not just a dead
# process. using node instead of curl/wget since it's already in the image
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD node -e "require('http').get({host:'localhost',port:process.env.PORT||8080,path:'/health',timeout:2000},(r)=>process.exit(r.statusCode===200?0:1)).on('error',()=>process.exit(1))"

CMD ["node", "src/index.js"]
