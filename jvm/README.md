# JVM node

Java and Kotlin need no SDK here: the node ships with erupt, so its annotations always match the server.
A service declares models with the regular `@Erupt` / `@EruptField` annotations and becomes a node by adding
one dependency.

| Stack | Artifact |
|-------|----------|
| Spring Boot 3.5 | `xyz.erupt:erupt-cloud-node-jpa` (JPA data layer), or the bare `erupt-cloud-node` |
| No Spring | [`xyz.erupt:erupt-cloud-node-lite`](https://github.com/erupts/erupt/tree/develop/erupt-cloud/erupt-cloud-node-lite) on the JDK's HTTP server, or mounted by `-solon`, `-quarkus`, `-micronaut`, `-vertx`, `-ktor`, `-servlet` |

`erupt-cloud-node` is the reference implementation of the node protocol every SDK here follows; the
erupt-cloud-node-lite README documents models, handlers, storage and the frameworks.

```xml
<dependency>
    <groupId>xyz.erupt</groupId>
    <artifactId>erupt-cloud-node-jpa</artifactId>   <!-- or erupt-cloud-node-lite / -solon / -quarkus ... -->
    <version>${erupt.version}</version>
</dependency>
```

With Spring the node is configured in `application.yml`:

```yaml
erupt:
  cloud-node:
    node-name: blog
    access-token: ${ERUPT_ACCESS_TOKEN}       # Node Config -> View Token on the server; never commit it
    server-addresses: http://erupt-server:8080 # several addresses are round-robined
    # host-address: http://10.0.0.12:9090      # only when the server cannot reach the auto-detected address
```

## Examples

- [`examples/conformance`](examples/conformance): the conformance fixture in Java, on erupt-cloud-node-lite;
- [`examples/blog`](examples/blog): the blog in Kotlin over H2, on erupt-cloud-node-lite;
- [`examples/spring-blog`](examples/spring-blog): the same blog on Spring Boot with erupt-cloud-node-jpa.

```bash
# lite: in an erupt checkout (until the version in examples/pom.xml is released)
mvn install -pl erupt-cloud/erupt-cloud-node-lite -am -DskipTests
# here
mvn -f jvm/examples/pom.xml package
python3 conformance/run.py -- java -jar jvm/examples/conformance/target/erupt-conformance.jar
java -jar jvm/examples/blog/target/erupt-blog.jar

# Spring, against the released erupt-cloud-node-jpa
mvn -f jvm/examples/spring-blog/pom.xml package
ERUPT_ACCESS_TOKEN=... ERUPT_SERVER=http://localhost:8080 PORT=9090 java -jar jvm/examples/spring-blog/target/erupt-node-blog-0.1.0.jar
```

Then on the server add menus of type `table` with values `blog.Article` and `blog.Category`.

## Differences worth knowing

- Field naming follows Java (`publishDate`); the other SDKs use whatever names the model declares.
- A wrong access token or a denied right answers **500** from the Spring node and **403** from the SDKs
  (`erupt-cloud/PROTOCOL.md` §8 proposes 403 for v1). The browser shows an error either way.
- The Spring node enforces the full annotation surface (sub-tables, Excel, attachments, DataProxy hooks…);
  the SDKs implement the levels listed in their READMEs.
