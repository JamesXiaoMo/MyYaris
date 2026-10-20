import 'package:flutter/foundation.dart';

/// 丰田专有 PID/DID 数据字典条目
@immutable
class ToyotaPidDefinition {
  final String category;
  final String header;
  final String command;
  final String name;
  final String unit;
  final String description;

  const ToyotaPidDefinition({
    required this.category,
    required this.header,
    required this.command,
    required this.name,
    required this.unit,
    required this.description,
  });
}

/// 丰田第四代 THS-II / TNGA 全球架构混动专用数据集
/// 对应 Car Scanner Profile:
/// `Toyota Corolla Hybrid 2020-, RAV4 Hybrid 2019-, Camry Hybrid 2018-, Avalon Hybrid 2019-`
class ToyotaTngaHybridProfile {
  static const String profileName =
      'Toyota Corolla Hybrid 2020-, RAV4 Hybrid 2019-, Camry Hybrid 2018-, Avalon Hybrid 2019- (TNGA THS-II)';

  /// 标准 SAE J1979 Mode 01 参数 (实车已验证开放)
  static const List<ToyotaPidDefinition> standardPidList = [
    ToyotaPidDefinition(
      category: '标准OBD (Mode 01)',
      header: '7DF',
      command: '010D',
      name: '车辆行驶车速',
      unit: 'km/h',
      description: 'SAE J1979 标准车速 PID',
    ),
    ToyotaPidDefinition(
      category: '标准OBD (Mode 01)',
      header: '7DF',
      command: '010C',
      name: '发动机实际转速',
      unit: 'rpm',
      description: '内燃机实际转速 (混动纯电停机时为0)',
    ),
    ToyotaPidDefinition(
      category: '标准OBD (Mode 01)',
      header: '7DF',
      command: '0105',
      name: '发动机冷却水温',
      unit: '°C',
      description: '发动机冷却液温度',
    ),
    ToyotaPidDefinition(
      category: '标准OBD (Mode 01)',
      header: '7DF',
      command: '0142',
      name: '控制模块供电电压',
      unit: 'V',
      description: 'ECU 内部低压 12V 供电端电压',
    ),
    ToyotaPidDefinition(
      category: '标准OBD (Mode 01)',
      header: '7DF',
      command: '01A6',
      name: '整车仪表累计总里程',
      unit: 'km',
      description: '整车高精度累计总里程 (0.1 km 精度)',
    ),
    ToyotaPidDefinition(
      category: '标准OBD (Mode 01)',
      header: '7DF',
      command: '015C',
      name: '发动机机油温度',
      unit: '°C',
      description: '机油温度传感器物理值',
    ),
    ToyotaPidDefinition(
      category: '标准OBD (Mode 01)',
      header: '7DF',
      command: '0111',
      name: '节气门开度',
      unit: '%',
      description: '发动机绝对节气门开度',
    ),
    ToyotaPidDefinition(
      category: '标准OBD (Mode 01)',
      header: '7DF',
      command: '0149',
      name: '油门踏板位置 D',
      unit: '%',
      description: '加速踏板位置传感器通道 D',
    ),
    ToyotaPidDefinition(
      category: '标准OBD (Mode 01)',
      header: '7DF',
      command: '014A',
      name: '油门踏板位置 E',
      unit: '%',
      description: '加速踏板位置传感器通道 E',
    ),
    ToyotaPidDefinition(
      category: '标准OBD (Mode 01)',
      header: '7DF',
      command: '0110',
      name: '进气空气质量流量 (MAF)',
      unit: 'g/s',
      description: '热线式质量流量计进气量',
    ),
    ToyotaPidDefinition(
      category: '标准OBD (Mode 01)',
      header: '7DF',
      command: '0133',
      name: '绝对大气压强',
      unit: 'kPa',
      description: '车辆外部绝对大气压',
    ),
    ToyotaPidDefinition(
      category: '标准OBD (Mode 01)',
      header: '7DF',
      command: '013C',
      name: '催化转化器温度 1',
      unit: '°C',
      description: '排气管三元催化转化器前段载体温度',
    ),
  ];

  /// 丰田 TNGA 专有 UDS Mode 22 DID 参数集
  static const List<ToyotaPidDefinition> proprietaryDidList = [
    ToyotaPidDefinition(
      category: 'TNGA混动核心 (0x7E2)',
      header: '7E2',
      command: '221024',
      name: '混动高压电池核心遥测',
      unit: 'SOC%, V, A, kW',
      description: '高压电池荷电状态 SOC、高压总压、充放电实时电流及充放电功率',
    ),
    ToyotaPidDefinition(
      category: 'TNGA混动核心 (0x7E2)',
      header: '7E2',
      command: '221100',
      name: '升压母线与逆变器热管理',
      unit: 'V, °C',
      description: '升压前电压 VL、升压后母线电压 VH、MG1/MG2 逆变器温度、变速箱油温',
    ),
    ToyotaPidDefinition(
      category: 'TNGA动力电池 (0x7EB)',
      header: '7EB',
      command: '222884',
      name: '动力电芯极值与单体压差',
      unit: 'V, mV',
      description: '最高电芯单体电压、最低电芯单体电压及全包最大单体电芯压差 Delta V',
    ),
    ToyotaPidDefinition(
      category: 'TNGA动力电池 (0x7EB)',
      header: '7EB',
      command: '222885',
      name: '动力电池包 6 点温感阵列',
      unit: '°C',
      description: '动力锂电池包内部 6 个高精度热敏探头实时温度',
    ),
    ToyotaPidDefinition(
      category: 'TNGA发动机ECM (0x7E0)',
      header: '7E0',
      command: '221234',
      name: '电子水泵与高阶热管理',
      unit: 'rpm, °C',
      description: '电子冷却水泵实际与目标转速、发动机机油温度高阶传感器',
    ),
  ];
}
