#!/bin/bash
# ===============================================================
# 独立DTS注入脚本
# 功能：根据内核版本复制DTS文件并更新Makefile
# 使用：由recompile脚本调用
# 修复版本：1.1 - 修复所有致命bug和隐患
# ===============================================================

# 颜色定义
STEPS="[\033[95m STEPS \033[0m]"
INFO="[\033[94m INFO \033[0m]"
SUCCESS="[\033[92m SUCCESS \033[0m]"
WARNING="[\033[93m WARNING \033[0m]"
ERROR="[\033[91m ERROR \033[0m]"

# ======================== DTS路径配置 ========================
# 请根据实际情况修改以下路径配置

# DTS源根目录（相对于主脚本目录）
DTS_SOURCE_ROOT="${PWD}/custom-dts"

# DTS配置数组 - 每个条目定义一个需要处理的目录
# 格式: "源目录名:目标目录路径"
# 注意：源目录是相对于 custom-dts/linux-${kernel_version}/ 的
#       目标目录是相对于内核源码的（容器内路径）
DTS_CONFIGS=(
    # Rockchip系列
    "rockchip:arch/arm64/boot/dts/rockchip"
    
    # Amlogic系列
    "amlogic:arch/arm64/boot/dts/amlogic"
    
    # Allwinner系列
    "allwinner:arch/arm/boot/dts"
    "allwinner64:arch/arm64/boot/dts/allwinner"
    
    # 更多SOC类型可以继续添加...
    # "your_soc_source:your_target_path"
)

# ===============================================================
# 注意：以下变量需要从主脚本传递
# - kernel_version: 内核版本（如 6.1.y）
# - docker_container: Docker容器名称
# - current_path: 当前工作目录
# 
# 如果这些变量未定义，将使用以下默认值
: ${kernel_version:="6.1.y"}
: ${docker_container:="armbian-ophub"}
: ${current_path:="${PWD}"}
# ===============================================================

# ======================== 辅助函数 ========================

# 检查Docker容器是否运行
check_docker_container() {
    echo -e "${INFO} 检查Docker容器状态..."
    local container_status=$(docker inspect -f '{{.State.Running}}' "${docker_container}" 2>/dev/null)
    
    if [[ "${container_status}" == "true" ]]; then
        echo -e "${SUCCESS} Docker容器正在运行: ${docker_container}"
        return 0
    else
        echo -e "${ERROR} Docker容器未运行或不存在: ${docker_container}"
        echo -e "${WARNING} 尝试启动容器..."
        
        # 尝试启动容器
        if docker start "${docker_container}" >/dev/null 2>&1; then
            echo -e "${SUCCESS} 容器启动成功，等待5秒..."
            sleep 5
            return 0
        else
            echo -e "${ERROR} 无法启动容器"
            return 1
        fi
    fi
}

# 动态获取容器内的内核源码路径
get_kernel_source_dir() {
    echo -e "${INFO} 动态查找容器内核源码路径..."
    
    # 方法1: 查找常见的内核源码目录
    local possible_paths=(
        "/opt/kernel/compile-kernel/output/sources/linux-*"
        "/opt/kernel/compile-kernel/output/sources/linux-${kernel_version%%.*}.y"
        "/opt/kernel/compile-kernel/output/sources/linux"
        "/opt/kernel/compile-kernel/sources/linux-*"
        "/opt/kernel/linux-*"
    )
    
    local kernel_dir=""
    
    for pattern in "${possible_paths[@]}"; do
        # 使用find查找具体的linux目录
        local found_dir=$(docker exec -i "${docker_container}" \
            find /opt/kernel -type d -name "linux-*" 2>/dev/null | \
            grep -E "linux-.*${kernel_version%%.*}" | head -1)
        
        if [[ -n "${found_dir}" ]]; then
            kernel_dir="${found_dir}"
            break
        fi
    done
    
    # 方法2: 通过查找Makefile文件确定
    if [[ -z "${kernel_dir}" ]]; then
        kernel_dir=$(docker exec -i "${docker_container}" \
            find /opt/kernel -name "Makefile" -type f 2>/dev/null | \
            grep -E "/Makefile$" | head -1 | xargs dirname 2>/dev/null)
    fi
    
    # 方法3: 通过查找Kconfig文件确定
    if [[ -z "${kernel_dir}" ]]; then
        kernel_dir=$(docker exec -i "${docker_container}" \
            find /opt/kernel -name "Kconfig" -type f 2>/dev/null | \
            head -1 | xargs dirname 2>/dev/null | xargs dirname 2>/dev/null)
    fi
    
    if [[ -z "${kernel_dir}" ]]; then
        echo -e "${ERROR} 无法找到容器内的内核源码目录"
        echo -e "${WARNING} 尝试列出 /opt/kernel 目录内容:"
        docker exec -i "${docker_container}" ls -la /opt/kernel/ 2>/dev/null || true
        echo ""
        return 1
    fi
    
    echo -e "${SUCCESS} 找到内核源码目录: ${kernel_dir}"
    echo "${kernel_dir}"
    return 0
}

# 检查DTS源目录是否有效
check_dts_source_directory() {
    local dts_source_dir="$1"
    
    echo -e "${INFO} 验证DTS源目录结构..."
    
    if [[ ! -d "${dts_source_dir}" ]]; then
        echo -e "${ERROR} DTS源目录不存在: ${dts_source_dir}"
        return 1
    fi
    
    # 检查是否有任何SOC子目录存在
    local soc_count=0
    for config in "${DTS_CONFIGS[@]}"; do
        local source_dir=$(echo "${config}" | cut -d':' -f1)
        local full_source_path="${dts_source_dir}/${source_dir}"
        
        if [[ -d "${full_source_path}" ]]; then
            ((soc_count++))
            # 检查该目录下是否有.dts或.dtsi文件
            local dts_files=$(find "${full_source_path}" -maxdepth 1 -name "*.dts" -o -name "*.dtsi" 2>/dev/null | head -5)
            if [[ -n "${dts_files}" ]]; then
                echo -e "  ${SUCCESS} 发现有效目录: ${source_dir}"
            else
                echo -e "  ${WARNING} 目录为空: ${source_dir}"
            fi
        fi
    done
    
    if [[ ${soc_count} -eq 0 ]]; then
        echo -e "${ERROR} DTS源目录下未找到任何SOC配置的子目录"
        echo -e "${INFO} 可用的DTS版本目录:"
        ls -la "${DTS_SOURCE_ROOT}/" 2>/dev/null || echo "  ${WARNING} 无可用目录"
        return 1
    fi
    
    echo -e "${SUCCESS} 找到 ${soc_count} 个SOC配置目录"
    return 0
}

# 安全复制文件函数（避免空指针）
safe_copy_dts_files() {
    local source_dir="$1"
    local target_dir="$2"
    local kernel_dir="$3"
    
    local copied_count=0
    local error_count=0
    
    echo -e "${INFO} 扫描DTS文件..."
    
    # 使用find命令安全查找文件（避免数组扩展问题）
    while IFS= read -r -d '' dts_file; do
        if [[ -f "${dts_file}" ]]; then
            local filename=$(basename "${dts_file}")
            local target_path="${kernel_dir}/${target_dir}/${filename}"
            
            echo -e "  ${INFO} 处理: ${filename}"
            
            # 创建目标目录（如果不存在）
            docker exec -i "${docker_container}" mkdir -p "$(dirname "${target_path}")" 2>/dev/null
            
            # 复制文件到容器
            if docker cp "${dts_file}" "${docker_container}:${target_path}" >/dev/null 2>&1; then
                echo -e "    ${SUCCESS} 复制成功"
                ((copied_count++))
            else
                echo -e "    ${ERROR} 复制失败"
                ((error_count++))
            fi
        fi
    done < <(find "${source_dir}" -maxdepth 1 -type f \( -name "*.dts" -o -name "*.dtsi" \) -print0 2>/dev/null)
    
    if [[ ${copied_count} -eq 0 ]] && [[ ${error_count} -eq 0 ]]; then
        echo -e "  ${WARNING} 未找到.dts或.dtsi文件"
    fi
    
    echo -e "  ${INFO} 结果: ${copied_count} 成功, ${error_count} 失败"
    return ${copied_count}
}

# 智能查找Makefile中的dtb前缀行
find_makefile_prefix() {
    local makefile_path="$1"
    
    echo -e "${INFO} 查找Makefile中的dtb配置行..."
    
    # 尝试多种模式匹配Makefile中的dtb行
    local patterns=(
        "^[[:space:]]*dtb-\$\(CONFIG_[A-Za-z0-9_]+\)[[:space:]]*+="
        "^dtb-\$\(CONFIG_[A-Za-z0-9_]+\)[[:space:]]*+="
        "^[[:space:]]*dtb-\$\([A-Za-z0-9_]+\)[[:space:]]*+="
    )
    
    # 读取Makefile前20行（通常配置在前20行内）
    local makefile_content=$(docker exec -i "${docker_container}" \
        head -n 20 "${makefile_path}" 2>/dev/null)
    
    if [[ -z "${makefile_content}" ]]; then
        echo -e "  ${WARNING} 无法读取Makefile: ${makefile_path}"
        return 1
    fi
    
    # 逐行检查
    local line_num=0
    while IFS= read -r line; do
        ((line_num++))
        
        # 跳过空行和注释
        [[ -z "${line}" ]] && continue
        [[ "${line}" =~ ^[[:space:]]*# ]] && continue
        
        # 尝试匹配每种模式
        for pattern in "${patterns[@]}"; do
            if [[ "${line}" =~ ${pattern} ]]; then
                # 提取完整的dtb-$(CONFIG_XXX)部分
                if [[ "${line}" =~ (dtb-\$\(CONFIG_[A-Za-z0-9_]+\)) ]]; then
                    local prefix="${BASH_REMATCH[1]}"
                    echo -e "  ${SUCCESS} 在第 ${line_num} 行找到前缀: ${prefix}"
                    echo "${prefix}"
                    return 0
                elif [[ "${line}" =~ (dtb-\$\([A-Za-z0-9_]+\)) ]]; then
                    local prefix="${BASH_REMATCH[1]}"
                    echo -e "  ${SUCCESS} 在第 ${line_num} 行找到前缀: ${prefix}"
                    echo "${prefix}"
                    return 0
                fi
            fi
        done
    done <<< "${makefile_content}"
    
    echo -e "  ${WARNING} 未找到dtb配置行"
    echo -e "  ${INFO} Makefile前5行:"
    docker exec -i "${docker_container}" head -n 5 "${makefile_path}" 2>/dev/null | \
        while IFS= read -r line; do
            echo -e "    > ${line}"
        done
    return 1
}

# 更新Makefile函数
update_makefile() {
    local makefile_path="$1"
    local kernel_dir="$2"
    local target_dir="$3"
    local source_dir="$4"
    
    echo -e "${INFO} 更新Makefile: ${makefile_path}"
    
    # 检查Makefile是否存在
    if ! docker exec -i "${docker_container}" test -f "${makefile_path}" 2>/dev/null; then
        echo -e "  ${ERROR} Makefile不存在: ${makefile_path}"
        echo -e "  ${WARNING} 尝试创建Makefile..."
        
        # 创建目录和空的Makefile
        docker exec -i "${docker_container}" mkdir -p "$(dirname "${makefile_path}")" 2>/dev/null
        docker exec -i "${docker_container}" touch "${makefile_path}" 2>/dev/null
        
        if [[ $? -ne 0 ]]; then
            echo -e "  ${ERROR} 无法创建Makefile"
            return 1
        fi
    fi
    
    # 查找Makefile前缀
    local prefix=$(find_makefile_prefix "${makefile_path}")
    if [[ -z "${prefix}" ]]; then
        echo -e "  ${WARNING} 无法确定Makefile前缀，使用默认值"
        
        # 根据目标路径推断可能的前缀
        local inferred_prefix=""
        if [[ "${target_dir}" == *"rockchip"* ]]; then
            inferred_prefix="dtb-\$(CONFIG_ARCH_ROCKCHIP)"
        elif [[ "${target_dir}" == *"amlogic"* ]]; then
            inferred_prefix="dtb-\$(CONFIG_ARCH_MESON)"
        elif [[ "${target_dir}" == *"allwinner"* ]]; then
            inferred_prefix="dtb-\$(CONFIG_ARCH_SUNXI)"
        else
            inferred_prefix="dtb-\$(CONFIG_ARCH_GENERIC)"
        fi
        
        prefix="${inferred_prefix}"
        echo -e "  ${INFO} 使用推断的前缀: ${prefix}"
        
        # 在Makefile开头添加注释和配置
        local temp_file="/tmp/makefile_${RANDOM}.tmp"
        docker exec -i "${docker_container}" sh -c "echo '# Automatically generated by DTS inject script' > '${temp_file}'" 2>/dev/null
        docker exec -i "${docker_container}" sh -c "echo '# SPDX-License-Identifier: GPL-2.0' >> '${temp_file}'" 2>/dev/null
        docker exec -i "${docker_container}" sh -c "echo '' >> '${temp_file}'" 2>/dev/null
        
        # 保存临时文件内容
        docker exec -i "${docker_container}" cat "${makefile_path}" 2>/dev/null >> "${temp_file}" 2>/dev/null
        
        # 用临时文件替换原Makefile
        docker exec -i "${docker_container}" mv "${temp_file}" "${makefile_path}" 2>/dev/null
    fi
    
    # 对每个.dts文件添加一行到Makefile（不添加重复的）
    local added_count=0
    local skipped_count=0
    
    while IFS= read -r -d '' dts_file; do
        if [[ -f "${dts_file}" ]]; then
            local basename=$(basename "${dts_file}" .dts)
            local new_line="${prefix} += ${basename}.dtb"
            
            # 检查是否已存在（精确匹配整行）
            local exists=$(docker exec -i "${docker_container}" \
                grep -c "^[[:space:]]*${prefix}[[:space:]]*+=[[:space:]]*.*${basename}.dtb" \
                "${makefile_path}" 2>/dev/null || echo "0")
            
            if [[ "${exists}" == "0" ]]; then
                # 在Makefile末尾添加新行
                if docker exec -i "${docker_container}" sh -c "echo '${new_line}' >> '${makefile_path}'" 2>/dev/null; then
                    echo -e "  ${SUCCESS} 添加: ${new_line}"
                    ((added_count++))
                else
                    echo -e "  ${ERROR} 添加失败: ${new_line}"
                fi
            else
                echo -e "  ${WARNING} 已存在，跳过: ${basename}.dtb"
                ((skipped_count++))
            fi
        fi
    done < <(find "${source_dir}" -maxdepth 1 -type f -name "*.dts" -print0 2>/dev/null)
    
    echo -e "  ${INFO} Makefile更新完成: ${added_count} 添加, ${skipped_count} 跳过"
    
    # 显示Makefile最后几行确认
    echo -e "  ${INFO} Makefile末尾内容:"
    docker exec -i "${docker_container}" tail -n 10 "${makefile_path}" 2>/dev/null | \
        while IFS= read -r line; do
            echo -e "    > ${line}"
        done
    
    return ${added_count}
}

# ======================== 主注入函数 ========================

# DTS注入主函数
inject_custom_dts() {
    echo -e "${STEPS} 开始注入自定义DTS文件..."
    
    # 1. 检查Docker容器状态
    if ! check_docker_container; then
        echo -e "${ERROR} Docker容器检查失败，终止DTS注入"
        return 1
    fi
    
    # 2. 根据内核版本确定DTS源目录
    local dts_source_dir="${DTS_SOURCE_ROOT}/linux-${kernel_version}"
    
    # 3. 验证DTS源目录结构
    if ! check_dts_source_directory "${dts_source_dir}"; then
        echo -e "${ERROR} DTS源目录验证失败"
        return 1
    fi
    
    # 4. 动态获取容器内的内核源码路径
    local kernel_dir=$(get_kernel_source_dir)
    if [[ -z "${kernel_dir}" ]]; then
        echo -e "${ERROR} 无法获取内核源码目录，终止DTS注入"
        return 1
    fi
    
    echo -e "${INFO} 内核源码目录: ${kernel_dir}"
    
    # 5. 遍历所有配置的路径
    local total_configs=${#DTS_CONFIGS[@]}
    local processed_configs=0
    local total_files_copied=0
    local total_files_added=0
    local skipped_configs=0
    
    echo -e "${INFO} 开始处理 ${total_configs} 个配置..."
    
    for config in "${DTS_CONFIGS[@]}"; do
        ((processed_configs++))
        echo -e "\n${INFO} [${processed_configs}/${total_configs}] 处理配置: ${config}"
        
        # 解析配置：源目录名:目标目录路径
        local source_dir=$(echo "${config}" | cut -d':' -f1)
        local target_dir=$(echo "${config}" | cut -d':' -f2)
        
        # 完整的源路径
        local full_source_path="${dts_source_dir}/${source_dir}"
        
        echo -e "  源路径: ${full_source_path}"
        echo -e "  目标路径: ${target_dir}"
        
        # 检查源目录是否存在
        if [[ ! -d "${full_source_path}" ]]; then
            echo -e "  ${WARNING} 源目录不存在，跳过"
            ((skipped_configs++))
            continue
        fi
        
        # 6. 复制所有dts和dtsi文件到内核目录
        echo -e "  ${INFO} 复制DTS/DTSI文件..."
        local copy_result=0
        if safe_copy_dts_files "${full_source_path}" "${target_dir}" "${kernel_dir}"; then
            copy_result=$?
        fi
        
        if [[ ${copy_result} -eq 0 ]]; then
            echo -e "  ${WARNING} 没有文件需要复制，跳过Makefile更新"
            continue
        fi
        
        total_files_copied=$((total_files_copied + copy_result))
        
        # 7. 更新Makefile
        local makefile_path="${kernel_dir}/${target_dir}/Makefile"
        echo -e "  ${INFO} 更新Makefile: ${makefile_path}"
        
        if update_makefile "${makefile_path}" "${kernel_dir}" "${target_dir}" "${full_source_path}"; then
            local added_count=$?
            total_files_added=$((total_files_added + added_count))
        fi
    done
    
    # 8. 输出统计信息
    echo -e "\n${STEPS} DTS注入完成"
    echo -e "${INFO} 统计信息:"
    echo -e "  ${INFO} 处理的配置数: ${processed_configs}/${total_configs}"
    echo -e "  ${WARNING} 跳过的配置数: ${skipped_configs}"
    echo -e "  ${SUCCESS} 复制的文件数: ${total_files_copied}"
    echo -e "  ${SUCCESS} 添加到Makefile的行数: ${total_files_added}"
    
    if [[ ${total_files_copied} -eq 0 ]] && [[ ${skipped_configs} -eq ${total_configs} ]]; then
        echo -e "${WARNING} 没有处理任何文件，请检查配置和目录结构"
        return 1
    fi
    
    echo -e "${SUCCESS} DTS注入完成"
    return 0
}

# ======================== 脚本入口 ========================

# 如果直接运行此脚本（测试用），则执行注入函数
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo -e "${STEPS} DTS注入脚本 - 独立测试模式"
    echo -e "${WARNING} 注意：此脚本通常由recompile脚本调用"
    echo -e "${INFO} 当前配置:"
    echo -e "  kernel_version: ${kernel_version}"
    echo -e "  docker_container: ${docker_container}"
    echo -e "  current_path: ${current_path}"
    echo -e "  DTS_SOURCE_ROOT: ${DTS_SOURCE_ROOT}"
    echo ""
    
    # 询问是否继续（带超时）
    echo -e "${WARNING} 5秒后自动开始测试，按Ctrl+C取消..."
    for i in {5..1}; do
        echo -ne "  ${i}...\r"
        sleep 1
    done
    
    echo -e "\n${INFO} 开始DTS注入测试..."
    inject_custom_dts
    
    if [[ $? -eq 0 ]]; then
        echo -e "${SUCCESS} DTS注入测试成功"
        exit 0
    else
        echo -e "${ERROR} DTS注入测试失败"
        exit 1
    fi
fi
