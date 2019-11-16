---
title: Three Layer Cake
subtitle: "A maintainable architecture for an aggregation service"
tags: ["micro-services", "spring-boot"]
date: 2019-11-08
---

# What is an aggregation service? 
An aggregation service is generally a RESTful web service that aggregates across multiple micro-services. 
It has a broader definition as described in [Enterprise Integration Patterns](https://camel.apache.org/manual/latest/aggregate-eip.html)
but I am going to focus on using it in a micro-service context.
![Aggregator EIP](/aggregator_eip_pattern.png)
When to use? 
Imagine you work at an e-commerce company that is revamping the products section of its website. 
The requirements state the product page needs bits of catalog, inventory, and pricing data. The data is spread across 3 domain bounded micro-services.
This is when the aggregation service is useful.


## Breaking down the three layer cake
The three layer cake can be broken down into controllers, services, and repositories.
![three-layer-cake](/three-layer-cake.png)

A core goal is to support changes to the external layers without changing the business logic of the application. 
The controller should fully encapsulate the externally exposed api while the application's external downstream apis are encapsulated in repositories. 
The service layer **Always** only uses internal data types. The service should **never** be exposed to the type of the HTTP response body or the types of the external data sources. 
Versions of your API **WILL CHANGE** over time, along with the services that your application consumes. 
If your application structure doesn't support changing the layers independently, the code will become a mess over time.
The example code uses Java and Spring, but the concepts apply to other languages and frameworks.
There will be a future post on how to use Spring to handle cross-cutting concerns such as authentication, bean validation, configuration, error handling, and logging. 

#### package structure
```
└── dev
    └── rambling
        └── threelayercake
            ├── controllers
            ├── services
            ├── model
            ├── repositories
            └── util
``` 

#### Sequence Diagram

 
{{<mermaid>}}
sequenceDiagram
    participant consumer
    participant ProductsController
    participant ProductService
    participant InventoryFacade
    participant CatalogRepository
    participant PricingRepository
    participant InventoryRepository
    participant LegacyInventoryRepository
    consumer->>+ProductsController: GET /v2/products/{upc}
    ProductsController->>+ProductService: get Product for ProductRequest
    ProductService-x+CatalogRepository: fetch data
    ProductService-xPricingRepository: fetch data
    ProductService-xInventoryFacade: fetch data from multiple sources
    InventoryFacade-xInventoryRepository: fetch data
    InventoryFacade-xLegacyInventoryRepository: fetch data
    InventoryFacade-xProductService: ProductInventoryData
    CatalogRepository-xProductService: ProductCatalogData
    PricingRepository-x-ProductService: ProductPricingData
    ProductService->>-ProductsController: Product
    ProductsController->>-consumer: HTTP status 200, body Product resource in v2 format 
{{< /mermaid >}} _(transformer components were omitted for brevity)_

Lets take a dive into in each layer...


### Controllers
#### Responsibilities
- expose operations on a resource
- validate inbound request
- transform to an internal model if needed
- delegate to work to the business logic layer
- form response to calling client

#### structure
```
│   ├── product
│   │   ├── ProductController.java
│   │   ├── ProductControllerRequestValidator.java
│   │   ├── ProductRequestTransformer.java
│   │   ├── ProductResponseTransformer.java
│   │   └── model
│   │       ├── ProductRequest.java
│   │       ├── ProductResponseV1.java
│   │       └── ProductResponseV2.java
```
#### example 
``` java
    /**
     * Retrieve product information by upc
     * @deprecated
     * <p> Use /v2/products/{upc} instead
     */
    @GetMapping("/v1/productByUpc")
    public ResponseEntity<ProductResponseV1> nonRestfulProducts(@RequestBody ProductRequest productRequest) {
        productControllerRequestValidator.validateUpc(productRequest);
        ProductRequestContext productRequestContext = productRequestTransfomer.transform(productRequest);
        Product product = productService.findByUpc(productRequestContext);
        return ResponseEntity.ok(product);
    }

    @GetMapping("/v2/products/{upc}")
    public ResponseEntity<ProductResponseV2> product(@PathVariable("upc") String upc,
                                           @RequestParam("requestedFields") String[] requestedFields,
                                           @RequestParam("sellingLocationIds") String[] sellingLocationIds) {
        ProductRequestContext productRequest = productRequestTransfomer.transform(upc, requestedFields, sellingLocationIds);
        productControllerRequestValidator.validateUpc(productRequest);
        return productService.findByUpc(productRequest)
                .map(ProductResponseTransformer::v2)
                .ifPresentOrElse(ResponseEntity::ok, ResponseEntity::notFound);
    }

    @ExceptionHandler(RequestValidationException.class)
    public ResponseEntity<?> handleException(RequestValidationException e) {
        return ResponseEntity.badRequest().body(new AppError(e));
    }

    @ExceptionHandler(AppException.class)
    public ResponseEntity<?> handleException(AppException e) {
        return ResponseEntity.status(HttpStatus.INTERNAL_SERVER_ERROR).body(new AppError(e));
    }
```
The inclusion of multiple versions in the example was not an accident. It is essential to think about how the application structure will handle change over time because it will change. 
The original author was still learning about REST and how to structure an api and eventually saw a better way. 
This better way required breaking api changes, and the api consumers needed a gradual migration path.
The use of `ProductRequestContext productRequest = productRequestTransfomer.transform(upc, requestedFields, sellingLocationIds)` allows the consumers to choose which format they need and the developers only need to support one model. 
Originally, the v1 `ProductRequest` object was passed into the service. 
Once the need for v2 came, the broken encapsulation was refactored to ensure changes to one layer do not affect the others.

### Services
#### Responsibilities
- Coordinate between repositories. 
- Fetch the appropriate data based on the request context and feature flags.
- Delegate to a facade when multiple repositories make up a single domain
- Invoke a creator/transform to get the target object after the required data is retrieved

#### structure
```
├── services
│   └── product
│       ├── InventoryFacade.java
│       ├── ProductTransformer.java
│       └── ProductService.java
├── model
│   ├── product
│   │   ├── Product.java
│   │   ├── ProductRequestContext.java
│   │   ├── ProductCatalogData.java
│   │   ├── ProductPricingData.java
│   │   └── ProductInventoryData.java
```

#### example product service
``` java
    @Autowired
    public ProductService(final CatalogRepository catalogRepository,
                          final PricingRepository pricingRepository,
                          final InventoryFacade inventoryFacade,
                          final ProductTransformer productTransformer) {

        this.catalogRepository = catalogRepository;
        this.pricingRepository = pricingRepository;
        this.inventoryFacade = inventoryFacade;
        this.productTransformer = productTransformer;
    }

    public Optional<Product> findByUpc(final ProductRequestContext requestContext) {
        ProductCatalogData productCatalogData = catalogRepository.fetchProductInfo(requestContext.getUpc());
        ProductPricingData productPricingData = pricingRepository.fetchPricing(requestContext.getUpc());
        ProductInventoryData productInventoryData = inventoryFacade.determineInventory(requestContext.getUpc());
        return productTransformer.transform(requestContext, productCatalogData, productPricingData, productInventoryData);
    }
```
The `ProductService` does the coordination across the domains. It delegates to the correct repository and uses a transformer
to combine the relevant data. This structure should be easy to test and understand the required inputs for a Product. 
A critical point is that the service layer only uses internal data types.  

#### example inventory facade
```java
    @Autowired
    public InventoryFacade(final InventoryRepository inventoryRepository,
                           final LegacyInventoryRepository legacyInventoryRepository) {
        this.inventoryRepository = inventoryRepository;
        this.legacyInventoryRepository = legacyInventoryRepository;
    }

    public ProductInventoryData determineInventory(String upc){
        try {
            return inventoryRepository.fetchProductInfo(upc);
        } catch (RepositoryException e){
            return legacyInventoryRepository.fetchInventory(upc);
        }
    }
```
The Facade concept is introduced here as a way to abstract multiple repositories, of the same domain, and keep the complexity 
of the primary service low and easily testable. The Facade pattern is not new and more information can be found [here](https://java-design-patterns.com/patterns/facade).

### Repositories
#### Responsibilities
- convert to external model
- invoke external http api/jdbc/grpc/queue/etc
- convert back to internal model

#### structure
```
│   ├── catalog
│   │   ├── CatalogAuthInterceptor.java
│   │   ├── CatalogConfiguration.java
│   │   ├── CatalogRepository.java
│   │   ├── CatalogTransformer.java
│   │   └── model
│   │       └── CatalogResponse.java
```


#### example repository
```java
    @Autowired
    public CatalogRepository(final CatalogConfiguration catalogConfiguration,
                             final RestTemplate catalogRestTemplate,
                             final CatalogTransformer catalogTransformer) {
        this.catalogConfiguration = catalogConfiguration;
        this.catalogResttemplate = catalogRestTemplate;
        this.catalogTransformer = catalogTransformer;
    }

    public ProductCatalogData fetchProductInfo(String upc){
        CatalogResponse catalogResponse = catalogRestTemplate.getForEntity(
            catalogConfiguration.getUrl, CatalogResponse.class, upc
        ).getBody();
        return catalogTransformer.transform(catalogResponse);
    }
```

`catalogTransformer.transform(catalogResponse)` is a very important line. This is where the external model is converted
into an internal model. This transformation helps protect your application from external changes. Now the Catalog service
owner can change its response format, and the only change required is to update the transformer. The same principles
apply to the formation of the outbound request. Consider a situation where you need to update a catalog item, the update 
would require an HTTP POST where the body contained the update. The structure of the request body is subject to change over time. 
The responsibility of building that request body belongs to the repository layer and can/should be delegated to a transformer. 
The `ProductService` must not build the catalog update request body. If the request format ever changes, 
which it will, that change will span multiple layers of the application and breaks the intended encapsulation.

## Conclusion

Use the Three Layer Cake architecture when aggregating over multiple domains. 
If multiple repositories make up a single domain, then a facade service may be in order. 
Most importantly, this architecture optimizes for change. 
