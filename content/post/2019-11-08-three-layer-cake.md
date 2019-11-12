---
title: Three Layer Cake
subtitle: "A maintainable architecture for an aggregation service"
tags: ["micro-services", "spring-boot"]
date: 2019-11-08
---

# What is an aggregation service? 
An aggregation service is generally a restful webservice that aggregates across multiple micro services. 
When to use? 
Imagine you work at an e-commerce that is revamping the products section of its website. 
The requirements state the product page needs bits of catalog, inventory, and pricing data. The data is spread across three domain bounded micro-services.
This is when the aggregation service is useful. It can also be described as an orchestration service.

## Breaking down the three layer cake
The three layer cake can be broken down into controllers, services, and repositories.
A core goal is to support changes to the external layers without changing the business logic of of the application. 
The controller should fully encapsulate the externally exposed api while the applications external downstream apis are encapsulated in repositories. 
The service layer **Always** only uses internal data types. The service should **never** be exposed to the type of the HTTP response body or the types of the external data sources. 
The example code uses Java and Spring but the concepts applies to other languages and frameworks.
There will be a future post on how to use Spring to handle cross cutting concerns such as authentication, bean validation, configuration, error handling and logging. 

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
    consumer->>ProductsController: GET /v2/products/{upc}
    ProductsController->>ProductService: get Product for ProductRequest
    ProductService-xCatalogRepository: fetch data
    ProductService-xPricingRepository: fetch data
    ProductService-xInventoryFacade: fetch data from multiple sources
    InventoryFacade-xInventoryRepository: fetch data
    InventoryFacade-xLegacyInventoryRepository: fetch data
    InventoryFacade-xProductService: ProductInventoryData
    CatalogRepository-xProductService: ProductCatalogData
    PricingRepository-xProductService: ProductPricingData
    Note over ProductService: create Product from ProductCatalogData, ProductPricingData, and InventoryFacade
    ProductService->>ProductsController: Product
    ProductsController->>consumer: HTTP status 200, body Product resource in v2 format 
{{< /mermaid >}}

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

### Controllers
#### Responsibilities
- expose operations on a resource
- validate inbound request
- transform to an internal model if needed
- delegate to work to business logic layer
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

### Services
#### Responsibilities
- Coordinate between repositories. 
- Fetch the appropriate data based on the request context and feature flags.
- Delegate to a facade when there are multiple repositories that make up a single domain
- Invoke a creator/transform to get target object after the required data is retrieved

#### structure
```
├── services
│   └── product
│       ├── InventoryFacade.java
│       ├── ProductCreator.java
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
                          final ProductCreator productCreator) {

        this.catalogRepository = catalogRepository;
        this.pricingRepository = pricingRepository;
        this.inventoryFacade = inventoryFacade;
        this.productCreator = productCreator;
    }

    public Optional<Product> findByUpc(final ProductRequestContext requestContext) {
        ProductCatalogData productCatalogData = catalogRepository.fetchProductInfo(requestContext.getUpc());
        ProductPricingData productPricingData = pricingRepository.fetchPricing(requestContext.getUpc());
        ProductInventoryData productInventoryData = inventoryFacade.determineInventory(requestContext.getUpc());
        return productCreator.create(requestContext, productCatalogData, productPricingData, productInventoryData);
    }
```

#### example inventory facade
```java
    @Autowired
    public InventoryFacade(final InventoryRepository inventoryRepository,
                           final LegacyInventoryRepository legacyInventoryRepository) {
        this.inventoryRepository = inventoryRepository;
        this.legacyInventoryRepository = legacyInventoryRepository;
    }

    // todo implement circuit breaker with resilience4j
    public ProductInventoryData determineInventory(String upc){
        try {
            return inventoryRepository.fetchProductInfo(upc);
        } catch (RepositoryException e){
            return legacyInventoryRepository.fetchInventory(upc);
        }
    }
```


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


#### example repository with caching
```java
    @Autowired
    public CatalogRepository(final CatalogConfiguration catalogConfiguration,
                             final RestTemplate catalogRestTemplate,
                             final CatalogTransformer catalogTransformer) {
        this.catalogConfiguration = catalogConfiguration;
        this.catalogResttemplate = catalogResttemplate;
        this.catalogTransformer = catalogTransformer;
    }

    // todo implement caching
    public ProductCatalogData fetchProductInfo(String upc){
        CatalogResponse catalogResponse = catalogResttemplate.getForEntity(
            catalogConfiguration.getUrl, CatalogResponse.class, upc
        ).getBody();
        return catalogTransformer.transform(catalogResponse);
    }
```

