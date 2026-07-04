import numpy as np
from numpy.polynomial.legendre import legval
x = 0.5
for n in range(1, 5):
    c = [0] * (n + 1)
    c[n] = 1
    print(f"P_{n}(0.5) = {legval(x, c)}")
