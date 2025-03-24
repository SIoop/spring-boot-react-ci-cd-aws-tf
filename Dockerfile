# Use an official OpenJDK 17 runtime as a parent image
FROM openjdk:8-jdk

# Set the working directory inside the container
WORKDIR /app

# Copy the Maven build output (assumes JAR is built outside Docker)
COPY target/*.jar app.jar

# Expose the application port (change if needed)
EXPOSE 80

# Run the Spring Boot application
ENTRYPOINT ["java", "-jar", "app.jar"]
