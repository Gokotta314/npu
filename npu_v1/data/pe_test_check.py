# coding: utf-8
import numpy as np
import torch
import struct

def bf16_to_float(bf16_bits):
    if bf16_bits == 0x7FC0:
        return float('nan')
    elif bf16_bits == 0x7F80:
        return float('inf')
    elif bf16_bits == 0xFF80:
        return float('-inf')
    
    uint32_val = (bf16_bits << 16)
    float32_bytes = struct.pack('I', uint32_val)
    return struct.unpack('f', float32_bytes)[0]

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

def read_vcs_results(start_line, end_line):
    vcs_results = []
    try:
        with open('pe_test_results.txt', 'r') as f:
            lines = f.readlines()
            for i in range(start_line, min(end_line, len(lines))):
                line = lines[i].strip()
                vcs_results.append(int(line, 16))
    except FileNotFoundError:
        print("错误：找不到仿真结果文件")
    
    return vcs_results

def pytorch_bf16_reference(a_float, b_float, operation):

    a_bf16 = torch.tensor(a_float, dtype=torch.bfloat16)
    b_bf16 = torch.tensor(b_float, dtype=torch.bfloat16)
    
    if operation == 'add':
        result_bf16 = a_bf16 + b_bf16
    elif operation == 'mul':
        result_bf16 = a_bf16 * b_bf16
    else:
        raise ValueError("操作类型必须是 'add' 或 'mul'")

    return result_bf16.float().item()

def run_accuracy_test(vcs_sum, vcs_prod):
    for i, (a_float, b_float) in enumerate(test_vectors):       
        if np.isnan(a_float) or np.isnan(b_float):
            expected_sum = float('nan')
            expected_prod = float('nan')
        else:
            expected_sum = pytorch_bf16_reference(a_float, b_float, 'add')
            expected_prod = pytorch_bf16_reference(a_float, b_float, 'mul')

        vcs_sum_float = bf16_to_float(vcs_sum[i])
        vcs_prod_float = bf16_to_float(vcs_prod[i])
        
        check_accuracy(a_float, b_float, expected_sum, vcs_sum_float, "加法", i)
        check_accuracy(a_float, b_float, expected_prod, vcs_prod_float, "乘法", i)

def check_accuracy(a, b, expected, actual, operation, test_id):
    if np.isnan(expected) and np.isnan(actual):
        print(f"测试{test_id}: {operation} NaN处理正确")
        return True
    elif np.isinf(expected) and np.isinf(actual) and np.sign(expected) == np.sign(actual):
        print(f"测试{test_id}: {operation} 无穷大处理正确")
        return True
    elif abs(expected - actual) < 1e-3:
        print(f"测试{test_id}: {operation} 精度合格")
        print(f"   期望: {expected}, 实际: {actual}, 误差: {abs(expected - actual)}")
        return True
    else:
        print(f"❌ 测试{test_id}失败: {a} {operation} {b}")
        print(f"   期望: {expected}, 实际: {actual}, 误差: {abs(expected - actual)}")
        return False

test_vectors = generate_test_vectors()
vcs_sum = read_vcs_results(2,len(test_vectors)+2)
vcs_prod = read_vcs_results(len(test_vectors)+3,2*(len(test_vectors)+2))
run_accuracy_test(vcs_sum, vcs_prod)
