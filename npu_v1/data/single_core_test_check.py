# coding: utf-8
import numpy as np
import torch
import struct

'''set number of rows and columns of systolic array'''
num = 4;

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

def float_to_bf16(float_val):
    
    float32_bytes = struct.pack('f', float_val)
    uint32_val = struct.unpack('I', float32_bytes)[0]
    
    bf16_bits = (uint32_val >> 16) & 0xFFFF
    return bf16_bits

def read_file(file_name, start_line, end_line):
    results = []
    try:
        with open(file_name, 'r') as f:
            lines = f.readlines()
            for i in range(start_line, end_line):
                line = lines[i].strip()
                results.append(int(line, 16))
    except FileNotFoundError:
        print("错误：找不到文件")
    
    return results

def extract_bf16_from_64bit(packed_value):
    bf16_values = []
    for i in range(num):
        bf16_val = (packed_value >> (i * 16)) & 0xFFFF
        bf16_values.append(bf16_val)
    return bf16_values

def compare_results(pytorch_result, vcs_results, tolerance=1e-3):
    """对比PyTorch和VCS的结果"""
    print("=" * 80)
    
    '''将PyTorch结果展平为一维数组'''
    pytorch_flat = pytorch_result.flatten()

    '''解析VCS结果'''
    vcs_bf16_values = []
    for packed_value in vcs_results:
        bf16_vals = extract_bf16_from_64bit(packed_value)
        vcs_bf16_values.extend(bf16_vals)

    passed_count = 0
    failed_count = 0
    max_error = 0.0
    
    for i in range(num*num):
        # 获取PyTorch结果（已经是浮点数）
        pytorch_float = pytorch_flat[i].float().item()
        
        # 将VCS的BF16位模式转换为浮点数
        vcs_float = bf16_to_float(vcs_bf16_values[i])
        
        # 检查特殊值
        if np.isnan(pytorch_float) and np.isnan(vcs_float):
            print(f"元素[{i}]: NaN处理正确")
            passed_count += 1
            continue
        elif np.isinf(pytorch_float) and np.isinf(vcs_float) and np.sign(pytorch_float) == np.sign(vcs_float):
            print(f"元素[{i}]: 无穷大处理正确")
            passed_count += 1
            continue
        
        # 计算误差
        absolute_error = abs(pytorch_float - vcs_float)
        
        if pytorch_float != 0:
            relative_error = absolute_error / abs(pytorch_float)
            error_measure = min(absolute_error, relative_error)
        else:
            error_measure = absolute_error
        
        # 更新最大误差
        if error_measure > max_error:
            max_error = error_measure
        
        # 检查精度
        if error_measure <= abs(pytorch_float)*tolerance:
            status = "✓ 通过"
            passed_count += 1
        else:
            status = "✗ 失败"
            failed_count += 1
        
        # 显示详细信息（前10个和失败的元素）
        if i < num*num or error_measure > tolerance:
            print(f"元素[{i:2d}]: {status}")
            print(f"    PyTorch: {pytorch_float:12.6e}")
            print(f"    VCS:     {vcs_float:12.6e}")
            print(f"    绝对误差: {absolute_error:.2e}")
            if pytorch_float != 0:
                print(f"    相对误差: {relative_error:.2e}")
            print(f"    判定误差: {error_measure:.2e}")
            print()
    
    # 统计结果
    total_count = passed_count + failed_count
    pass_rate = (passed_count / total_count) * 100 if total_count > 0 else 0
    
    print("=" * 80)
    print("统计结果:")
    print(f"通过: {passed_count}/{total_count} ({pass_rate:.2f}%)")
    print(f"失败: {failed_count}/{total_count}")
    print(f"最大误差: {max_error:.2e}")
    
    if failed_count == 0:
        print("✅ 所有测试通过！PyTorch与VCS结果一致")
        return True
    else:
        print("❌ 存在差异，需要检查硬件实现")
        return False

def main():
    '''读取测试向量'''
    test_vectors = read_file('single_core_test_vectors.txt',0,2*num*num)
    print(test_vectors)

    '''解析权重矩阵和激活矩阵'''
    print(f"解析权重矩阵和激活矩阵...")
    weight_matrix = []
    activate_matrix = []
    
    '''前num*num个数据为权重矩阵'''
    for i in range(num):
        row = []
        for j in range(num):
            idx = i * num + j
            if idx < num*num:
                row.append(bf16_to_float(test_vectors[idx]))
        weight_matrix.append(row)
    print(weight_matrix)

    '''接下来num*num个数据为激活矩阵'''
    for i in range(num):
        row = []
        for j in range(num):
            idx = num*num + i * num + j
            if idx < 2*num*num and idx < len(test_vectors):
                row.append(bf16_to_float(test_vectors[idx]))
        activate_matrix.append(row)
    print(activate_matrix)

    '''使用PyTorch计算矩阵乘法'''
    weight_tensor = torch.tensor(weight_matrix, dtype=torch.bfloat16)
    activate_tensor = torch.tensor(activate_matrix, dtype=torch.bfloat16)
    pytorch_result = torch.matmul(activate_tensor, weight_tensor)
    print(weight_tensor)
    print(activate_tensor)
    print(pytorch_result)

    '''读取VCS仿真结果'''
    vcs_results = read_file('single_core_test_results.txt', 1, num+1)

    '''对比结果'''
    success = compare_results(pytorch_result, vcs_results, tolerance=1e-3)
    
    return success

success = main()
if success:
    print("验证成功！硬件实现与PyTorch一致")
else:
    print("验证失败！存在差异需要检查")
