# gc

## Purpose
Garbage Collection management and utilities for the SageLang runtime.

## Features
- **Immix**: Implementation of the Immix mark-region garbage collector.
- **Management**: Fine-grained GC control for critical performance paths.

## Usage Example
```sage
import gc.immix
gc.collect() # Trigger manual collection
```
