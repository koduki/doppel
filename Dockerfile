# Use the official Ruby image from the Docker Hub
FROM ruby:3.4

# Set the working directory in the container
WORKDIR /usr/src/app

# Copy the Gemfile and Gemfile.lock into the container
COPY Gemfile Gemfile.lock ./

# Install the gems
RUN bundle install

# Copy the application code into the container
COPY . .

# Expose the port the app runs on
EXPOSE 4568

# The command to run the application
CMD ["bundle", "exec", "ruby", "app.rb", "-o", "0.0.0.0"]
