## Usage

### Install forge 
https://book.getfoundry.sh/getting-started/installation

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test -vv
```

### Omitted

Those questions were omitted during implementation:
* Which rewards distribution mechanism to use? (Discrete)
* Does `endEpoch` starts new epoch immediately? (Yes)

### Future enhancements

* Separate architecture into `Locker` and `Rewards` smart-contracts (imo)
* Tests optimizations and full test coverage
* Rounding optimizations
* Move TokenSet & ValidatorSet to libs
* Introduce batch locking and batch unlocking
* Gas optimizations with different techniques
* Implement LENS for external integrations (optional)
* Implement ERC721 Receiver with safeTransferFrom (optional)
* `lockFor()` for integrations with higher-level contracts & control mechanism (optional)
