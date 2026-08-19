import MLX

// Never run. Linking MLX is what causes its Metal kernels to be compiled.
print(MLXArray([1, 2, 3]).sum().item(Int.self))
