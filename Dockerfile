# Use the official Ruby image from the Docker Hub
FROM ruby:3.4-alpine3.20

ENV BUNDLE_DEPLOYMENT=1 \
    BUNDLE_WITHOUT=development:test \
    RACK_ENV=production \
    APP_ENV=production \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_BIN=/usr/local/bundle/bin \
    GEM_HOME=/usr/local/bundle \
    PATH="$BUNDLE_BIN:$PATH"

# Set the working directory in the container
WORKDIR /usr/src/app

# ランタイム
RUN apk add --no-cache tzdata ca-certificates

# ここを追加（ビルド依存）
RUN apk add --no-cache --virtual .build-deps build-base ruby-dev

# 依存インストール
COPY Gemfile Gemfile.lock ./
RUN bundle lock --add-platform x86_64-linux-musl && bundle install --jobs 4 --retry 3
RUN apk del .build-deps

# アプリ本体
COPY . .

# 最終ロックにも musl を付与（上の COPY で lock が戻るのを防ぐ）
RUN bundle lock --add-platform x86_64-linux-musl

# ここを追加：最終チェック。不足があれば一時的にビルド依存を入れて再インストール
RUN bundle check || (apk add --no-cache --virtual .build-deps build-base ruby-dev && bundle install --jobs 4 --retry 3 && apk del .build-deps)

# 非rootで実行
RUN adduser -D -h /usr/src/app app && chown -R app:app /usr/src/app /usr/local/bundle
USER app

# Expose the port the app runs on
EXPOSE 8080

# The command to run the application
CMD ["bundle", "exec", "ruby", "app.rb", "-o", "0.0.0.0"]
