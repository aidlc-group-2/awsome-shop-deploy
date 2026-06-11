# Java 服务 Dockerfile 参考（多阶段构建）
# 放到你的服务仓库根目录命名为 Dockerfile，按需修改端口。
# ---- build ----
FROM maven:3.9-eclipse-temurin-17 AS build
WORKDIR /app
COPY pom.xml .
RUN mvn -B -ntp dependency:go-offline
COPY src ./src
RUN mvn -B -ntp clean package -DskipTests

# ---- run ----
FROM eclipse-temurin:17-jre
WORKDIR /app
COPY --from=build /app/target/*.jar app.jar
# 改成你的服务端口：auth 8001 / product 8002 / points 8003 / order 8004 / gateway 8080
EXPOSE 8001
ENTRYPOINT ["java", "-jar", "app.jar"]
