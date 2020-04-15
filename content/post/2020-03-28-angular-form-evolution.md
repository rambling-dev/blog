---
title: "The Evolution of a Complex Angular Form"
subtitle: An example shopping cart from custom to maintainable
date: 2020-03-28T16:46:30-04:00
tags: ["angular", "reactive-forms", "control-value-accessor", "ngrx"]
draft: true
---

# the evolution of a complex angular form
This article will walk through the stages of building a complex. A checkout page will be our example context.
The requirements are to only let the user proceed to payment if all the products have valid quantities and the customer information is valid.
We start with a naive approach and refactor until we reach a "standard" approach and adding the next feature is simple and straight forward.
The goal is to maximise maintainability so new features can be implemented without drowning in prior tech debt.

# conclusion
The CVA interface creates a standard way to create complex components that compose together to create useful functionality.
The CVA replaces custom `@Input()`s and `@Outputs()` with a standard interface that is defined by the framework. 
This is in contrast to however the previous developer thought about naming conventions and how to share data.


