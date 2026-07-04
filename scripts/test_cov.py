import numpy as np

def rust_cov(x):
    n, m = x.shape
    centered = x.copy()
    for r in range(n):
        row_mean = np.sum(x[r, :]) / m
        centered[r, :] -= row_mean
    return (centered @ centered.T) / max(1, m - 1)

np.random.seed(42)
x = np.random.randn(62, 250)
print("Cov error:", np.max(np.abs(np.cov(x) - rust_cov(x))))
