#!/bin/bash
# ===============================================================
# DTS注入脚本（只能由主脚本调用）
# 功能：根据内核版本复制DTS文件并更新Makefile
# ===============================================================

# 颜色定义
STEPS="[\033[95m STEPS \033[0m]"
INFO="[\033[94m INFO \033[0m]"
SUCCESS="[\033[92m SUCCESS \033[0m]"
WARNING="[\033[93m WARNING \033[0m]"
ERROR="[\033[91m ERROR \033[0m]"

# ======================== 您的自定义配置 ========================
# 注意：按您的实际目录结构修改！！！

# DTS源根目录（必须修改为您的实际路径）
DTS_SOURCE_ROOT="${PWD}/custom-dts"

# DTS配置数组 - 每条配置定义一组DTS文件的复制规则
# 格式: "源路径:目标路径"
# 源路径：相对于 ${DTS_SOURCE_ROOT}/linux-${kernel_version}/ 的路径
# 目标路径：容器内核源码中的目标目录
# 
# 示例配置（请根据您的实际结构修改）：
DTS_CONFIGS=(
    # 示例：custom-dts/linux-6.1.y/arm64/rockchip → arch/arm64/boot/dts/rockchip
    "arm64/rockchip:arch/arm64/boot/dts/rockchip"
    
    # 示例：custom-dts/linux-6.1.y/arm64/amlogic → arch/arm64/boot/dts/amlogic
    # "arm64/amlogic:arch/arm64/boot/dts/amlogic"
    
    # 示例：custom-dts/linux-6.1.y/arm/allwinner → arch/arm/boot/dts
    # "arm/allwinner:arch/arm/boot/dts"
    
    # 添加更多配置...
)

# ======================== 核心逻辑 ========================

# 打印当前配置
print_config() {
    echo -e "${INFO} 当前配置："
    echo -e "  内核版本：${kernel_version}"
    echo -e "  Docker容器：${docker_container}"
    echo -e "  DTS源根目录：${DTS_SOURCE_ROOT}"
    echo -e "  配置数量：${#DTS_CONFIGS[@]}"
    echo ""
    
    for i in "${!DTS_CONFIGS[@]}"; do
        local config="${DTS_CONFIGS[$i]}"
        local source_path=$(echo "${config}" | cut -d':' -f1)
        local target_path=$(echo "${config}" | cut -d':' -f2)
        local full_source="${DTS_SOURCE_ROOT}/linux-${kernel_version}/${source_path}"
        
        echo -e "  [$((i+1))] 源：${source_path}"
        echo -e "      完整路径：${full_source}"
        echo -e "      目标：${target_path}"
    done
}

# 获取内核源码路径（简单方法）
get_kernel_dir() {
    # 尝试几个常见路径
    local dir=""
    
    # 方法1：查找linux-*目录
    dir=$(docker exec -i "${docker_container}" \
        find /opt/kernel -type d -name "linux-*" 2>/dev/null | head -1)
    
    if [[ -n "${dir}" ]]; then
        echo "${dir}"
        return 0
    fi
    
    # 方法2：查找Makefile
    dir=$(docker exec -i "${docker_container}" \
        find /opt/kernel -name "Makefile" -type f 2>/dev/null | \
        grep -E "/Makefile$" | head -1 | xargs dirname 2>/dev/null)
    
    if [[ -n "${dir}" ]]; then
        echo "${dir}"
        return 0
    fi
    
    # 如果都没找到，返回默认路径
    echo "/opt/kernel/linux-source"
}

# 更新Makefile函数
update_makefile() {
    local makefile_path="$1"
    local source_dir="$2"
    
    echo -e "${INFO} 更新Makefile：${makefile_path}"
    
    # 检查Makefile是否存在
    if ! docker exec -i "${docker_container}" test -f "${makefile_path}" 2>/dev/null; then
        echo -e "  ${WARNING} Makefile不存在，跳过更新"
        return 1
    fi
    
    # 读取Makefile的前几行找dtb配置
    local content=$(docker exec -i "${docker_container}" head -n 20 "${makefile_path}" 2>/dev/null)
    local prefix=""
    
    # 找dtb-$(CONFIG_XXX)行
    while IFS= read -r line; do
        if [[ "${line}" =~ ^[[:space:]]*dtb-\$\(CONFIG_[A-Za-z0-9_]+\)[[:space:]]*+= ]]; then
            prefix="${BASH_REMATCH[0]%%+=*}"
            prefix=$(echo "${prefix}" | sed 's/[[:space:]]*$//')  # 去掉末尾空格
            break
        fi
    done <<< "${content}"
    
    # 如果没找到，根据目标路径推断
    if [[ -z "${prefix}" ]]; then
        if [[ "${makefile_path}" == *"rockchip"* ]]; then
            prefix="dtb-\$(CONFIG_ARCH_ROCKCHIP)"
        elif [[ "${makefile_path}" == *"amlogic"* ]]; then
            prefix="dtb-\$(CONFIG_ARCH_MESON)"
        elif [[ "${makefile_path}" == *"sunxi"* ]] || [[ "${makefile_path}" == *"allwinner"* ]]; then
            prefix="dtb-\$(CONFIG_ARCH_SUNXI)"
        else
            prefix="dtb-\$(CONFIG_ARCH_GENERIC)"
        fi
        echo -e "  ${WARNING} 使用推断前缀：${prefix}"
    fi
    
    # 为每个.dts文件添加一行
    local added=0
    local skipped=0
    
    for dts_file in "${source_dir}"/*.dts; do
        if [[ -f "${dts_file}" ]]; then
            local basename=$(basename "${dts_file}" .dts)
            local new_line="${prefix} += ${basename}.dtb"
            
            # 检查是否已存在（使用更精确的匹配）
            local exists=$(docker exec -i "${docker_container}" \
                grep -c "^[[:space:]]*${prefix}[[:space:]]*+=[[:space:]]*.*${basename}.dtb" \
                "${makefile_path}" 2>/dev/null || echo "0")
            
            if [[ "${exists}" == "0" ]]; then
                if docker exec -i "${docker_container}" sh -c "echo '${new_line}' >> '${makefile_path}'" 2>/dev/null; then
                    echo -e "  ${SUCCESS} 添加：${new_line}"
                    ((added++))
                else
                    echo -e "  ${ERROR} 添加失败：${new_line}"
                fi
            else
                echo -e "  ${WARNING} 已存在：${basename}.dtb"
                ((skipped++))
            fi
        fi
    done
    
    echo -e "  ${INFO} 更新结果：${added} 添加，${skipped} 跳过"
    return $added
}

# 主函数：执行DTS注入
inject_custom_dts() {
    echo -e "${STEPS} 开始DTS注入"
    
    # 检查必要参数
    if [[ -z "${kernel_version}" ]]; then
        echo -e "${ERROR} 缺少kernel_version参数"
        return 1
    fi
    
    if [[ -z "${docker_container}" ]]; then
        echo -e "${ERROR} 缺少docker_container参数"
        return 1
    fi
    
    print_config
    
    # 1. 检查Docker容器
    if ! docker ps | grep -q "${docker_container}"; then
        echo -e "${ERROR} Docker容器未运行：${docker_container}"
        return 1
    fi
    
    # 2. 获取内核目录
    local kernel_dir=$(get_kernel_dir)
    echo -e "${INFO} 内核源码目录：${kernel_dir}"
    
    # 3. 遍历配置执行
    local processed=0
    local copied_files=0
    local updated_makefiles=0
    local skipped_configs=0
    
    for config in "${DTS_CONFIGS[@]}"; do
        ((processed++))
        
        # 解析配置
        local source_path=$(echo "${config}" | cut -d':' -f1)
        local target_path=$(echo "${config}" | cut -d':' -f2)
        local full_source="${DTS_SOURCE_ROOT}/linux-${kernel_version}/${source_path}"
        
        echo -e "\n${INFO} 处理配置 [${processed}]：${source_path} → ${target_path}"
        
        # 检查源目录是否存在
        if [[ ! -d "${full_source}" ]]; then
            echo -e "  ${WARNING} 源目录不存在：${full_source}"
            ((skipped_configs++))
            continue
        fi
        
        # 检查是否有DTS文件
        local dts_count=$(find "${full_source}" -maxdepth 1 -name "*.dts" 2>/dev/null | wc -l)
        if [[ ${dts_count} -eq 0 ]]; then
            echo -e "  ${WARNING} 没有.dts文件，跳过"
            ((skipped_configs++))
            continue
        fi
        
        # 创建目标目录
        local container_target="${kernel_dir}/${target_path}"
        docker exec -i "${docker_container}" mkdir -p "${container_target}" 2>/dev/null
        
        # 复制所有.dts和.dtsi文件
        local file_count=0
        for file in "${full_source}"/*.dts "${full_source}"/*.dtsi; do
            if [[ -f "${file}" ]]; then
                local filename=$(basename "${file}")
                if docker cp "${file}" "${docker_container}:${container_target}/${filename}" 2>/dev/null; then
                    echo -e "  ${SUCCESS} 复制：${filename}"
                    ((file_count++))
                    ((copied_files++))
                else
                    echo -e "  ${ERROR} 复制失败：${filename}"
                fi
            fi
        done
        
        # 更新Makefile（如果有.dts文件）
        if [[ ${file_count} -gt 0 ]]; then
            if update_makefile "${container_target}/Makefile" "${full_source}"; then
                ((updated_makefiles++))
            fi
        fi
    done
    
    # 结果统计
    echo -e "\n${STEPS} DTS注入完成"
    echo -e "${INFO} 处理配置：${processed}"
    echo -e "${WARNING} 跳过配置：${skipped_configs}"
    echo -e "${SUCCESS} 复制文件：${copied_files}"
    echo -e "${SUCCESS} 更新Makefile：${updated_makefiles}"
    
    if [[ ${copied_files} -eq 0 ]] && [[ ${skipped_configs} -eq ${processed} ]]; then
        echo -e "${ERROR} 没有处理任何文件，请检查配置和目录结构"
        return 1
    fi
    
    return 0
}

# 注意：此脚本没有独立运行逻辑，只能由主脚本调用
