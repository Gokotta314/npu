# coding: utf-8
import numpy as np
import torch
import struct

def generate_test_vectors():
    test_vectors = []
    
    basic_cases = [1.0, 2.0, 0.5, -1.0, 100.0, 0.1]
    for a in basic_cases:
        for b in basic_cases:
            test_vectors.append((a, b))
    
    boundaries = [0.0, -0.0, 6.10e-5, -6.10e-5, 65504.0, -65504.0, 1.17549e-38, -1.17549e-38, 3.38953e+38, -3.38953e+38]
    for bound in boundaries:
        test_vectors.append((bound, 1.0))
        test_vectors.append((bound, -1.0))
        test_vectors.append((bound, bound))
    
    specials = [float('inf'), float('-inf'), float('nan')]
    for spec in specials:
        for normal in [0.0, 1.0, -1.0]:
        	test_vectors.append((spec, normal))
        	test_vectors.append((spec, spec))
    
    subnormals = [1.0e-5, 2.0e-6, 1.0e-10, 1.0e-20]
    for sub in subnormals:
        test_vectors.append((sub, sub))
        test_vectors.append((sub, 100))
        test_vectors.append((sub, 1.0))
    
    return test_vectors

def save_test_vectors_to_txt(test_vectors, filename='pe_test_vectors.txt'):
    with open(filename, 'w', encoding='utf-8') as file:
        
        for i, (a_float, b_float) in enumerate(test_vectors):
            a_bf16 = torch.tensor(a_float, dtype=torch.bfloat16)
            b_bf16 = torch.tensor(b_float, dtype=torch.bfloat16)
            
            a_int = a_bf16.view(torch.int16).item() & 0xFFFF
            b_int = b_bf16.view(torch.int16).item() & 0xFFFF

            file.write("%04x\n%04x\n" % (a_int, b_int))

test_vectors = generate_test_vectors()
save_test_vectors_to_txt(test_vectors, 'pe_test_vectors.txt')
print("测试向量已保存到 pe_test_vectors.txt")

