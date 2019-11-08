---
title: Three Layer Cake
subtitle: "A maintainable architecture for an aggregation service"
tags: ["micro-services", "spring-boot"]
date: 2019-11-08
---

# What is an aggregation service? 
An aggregation service is generally a restful webservice that aggregates across multiple micro services. 
When to use? 
Imagine you work at an e-commerce that is revamping the products section of its website. Your company has also adopted micro services, and the requirements state the product page needs bits of catalog, inventory, and pricing data. Since, your company definitely has domain bounded services you need fetch data from at least 3  domains. This is when the aggregation service is useful. It can also be described as an orchestration service.



## Breaking down the three layer cake
The three layer cake can be broken down into controllers, services, and repositories. Spring also conveniently provides annotations to represent each layer.

#### package structure
```
└── dev
    └── rambling
        └── threelayercake
            ├── controllers
            ├── logic
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
```
#### example 
``` java
    /**
     * Retrieve product information by upc
     * @deprecated
     * <p> Use /v2/products/{upc} instead
     */
    @GetMapping("/v1/productByUpc")
    public ResponseEntity<Product> nonRestfulProducts(@RequestBody ProductRequestContext productRequest) {
        productControllerRequestValidator.validateUpc(productRequest);
        Product product = productService.findByUpc(productRequest);
        return ResponseEntity.ok(product);
    }

    @GetMapping("/v2/products/{upc}")
    public ResponseEntity<Product> product(@PathVariable("upc") String upc,
                                           @RequestParam("requestedFields") String[] requestedFields,
                                           @RequestParam("sellingLocationIds") String[] sellingLocationIds) {
        ProductRequestContext productRequest = productRequestTransfomer.transform(upc, requestedFields, sellingLocationIds);
        productControllerRequestValidator.validateUpc(productRequest);
        return productService.findByUpc(productRequest)
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

#### structure
```
            │   ├── product
            │   │   ├── ProductController.java
            │   │   ├── ProductControllerRequestValidator.java
            │   │   ├── ProductRequestTransformer.java
            │   │   └── model
            │   │       └── ProductRequestContext.java
```
### Services
#### Responsibilities
- Coordinate between repositories. 
- Fetch the appropriate data based on the request context and feature flags.
- Delegate to a facade when there are multiple repositories that make up a single domain
- Invoke a creator/transform to get target object after the required data is retrieved

#### example generic service
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
        int availableQuantity = inventoryFacade.determineInventory(requestContext.getUpc());
        return productCreator.create(requestContext, productCatalogData, productPricingData, availableQuantity);
    }
```

#### example facade
```java
    @Autowired
    public InventoryFacade(final InventoryRepository inventoryRepository,
                           final LegacyInventoryRepository legacyInventoryRepository) {
        this.inventoryRepository = inventoryRepository;
        this.legacyInventoryRepository = legacyInventoryRepository;
    }

    // todo implement circuit breaker with resilience4j
    public int determineInventory(String upc){
        try {
            return inventoryRepository.fetchProductInfo(upc);
        } catch (RepositoryException e){
            return legacyInventoryRepository.fetchInventory(upc);
        }
    }
```

#### structure
```
            ├── logic
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
            │   │   └── ProductData.java
```

### Repositories
#### Responsibilities
- convert to external model
- invoke external http api/jdbc/grpc/queue/etc
- convert back to internal model

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
