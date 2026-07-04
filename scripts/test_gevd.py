import numpy as np
import scipy.linalg

# Create random matrices
np.random.seed(42)
A = np.random.randn(5, 5)
A = A @ A.T

B = np.random.randn(5, 5)
B = B @ B.T + np.eye(5) * 0.1

vals, vecs = scipy.linalg.eigh(A, B)
idx = np.argsort(vals)[::-1]
vals = vals[idx]
vecs = vecs[:, idx]

print("Python Evals:")
print(vals)
print("Python Evecs:")
print(vecs)
