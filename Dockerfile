# Use the official Ruby image from the Docker Hub
FROM ruby:3.4-alpine3.20

ENV BUNDLE_WITHOUT=development:test \
    RACK_ENV=production \
    APP_ENV=production \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_BIN=/usr/local/bundle/bin \
    GEM_HOME=/usr/local/bundle \
    PATH="$BUNDLE_BIN:$PATH"

# Set the working directory in the container
WORKDIR /usr/src/app

# ランタイム
RUN apk add --no-cache tzdata ca-certificates libstdc++

# ここを追加（ビルド依存）
RUN apk add --no-cache --virtual .build-deps build-base ruby-dev

# 依存インストール
# Copy Gemfile and Gemfile.lock
COPY Gemfile* ./

# Force re-installation by removing Gemfile.lock and then bundling
RUN rm -f Gemfile.lock && \
    echo "Forcing gem re-installation from Gemfile" && \
    bundle install --jobs 4 --retry 3

RUN apk del .build-deps

# アプリ本体
COPY . .

# 非rootで実行
RUN adduser -D -h /usr/src/app app && chown -R app:app /usr/src/app /usr/local/bundle
USER app

# Expose the port the app runs on
EXPOSE 8080

# The command to run the application
CMD ["bundle", "exec", "rackup", "-p", "8080"]
