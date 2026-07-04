import numpy as np
from numpy.polynomial.legendre import legval
factors = [(2 * n + 1) / (n**4 * (n + 1)**4 * 4 * np.pi) for n in range(1, 6)]
x = 0.5
print("Python:")
for n in range(1, 6):
    c = [0] * (n + 1)
    c[n] = 1
    pn = legval(x, c)
    print(f"n={n}, pn={pn}, factor={factors[n-1]*4*np.pi}, term={pn * factors[n-1]*4*np.pi}")
