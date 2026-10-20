enum ObdConnectionStatus {
  disconnected,
  scanning,
  connecting,
  initializing,
  ready,
  error,
}

class ObdTelemetry {
  // --- 混动动力电池与电驱系统 (HV / EVB) ---
  final double? batterySoc; // 动力电池电量百分比 (%)
  final double? batteryVoltage; // 动力电池总电压 (V)
  final double? batteryCurrent; // 充放电实时电流 (A, 负放正充)
  final double? batteryPowerKw; // 实时充放功率 (kW)
  final double? maxCellVoltage; // 最高单体电压 (V)
  final double? minCellVoltage; // 最低单体电压 (V)
  final double? avgCellVoltage; // 平均单体电压 (V)
  final double? cellDeltaVoltage; // 单体电芯最大压差 (V)
  final List<double> batteryTemperatures; // 电池包 6 点温度监控 (°C)
  final double? voltageBeforeBoost; // VL 升压前电压 (V)
  final double? voltageAfterBoost; // VH 升压后电压 (V)
  final double? mg1InverterTemp; // MG1 发电机逆变器温度 (°C)
  final double? mg2InverterTemp; // MG2 电动机逆变器温度 (°C)
  final double? transaxleOilTemp; // 电驱变速箱油温 (°C)
  final double? mg1Rpm; // MG1 发电机转速 (rpm)
  final double? mg2Rpm; // MG2 驱动电机转速 (rpm)
  final double? mg2Torque; // MG2 驱动电机扭矩 (Nm)
  final double? regenBrakingTorque; // 请求再生制动力矩 (Nm)
  final double? batteryRemainingLife; // 电池健康度 SOH (%)

  // --- 发动机与能耗 (ECM / Powertrain) ---
  final double? speedKmh; // 车速 (km/h)
  final double? engineRpm; // 发动机转速 (RPM)
  final double? coolantTemp; // 发动机冷却水温 (°C)
  final double? engineOilTemp; // 机油温度 (°C)
  final double? engineOilPressure; // 机油压力 (kPa)
  final double? electricWaterPumpRpm; // 电子水泵实际转速 (RPM)
  final double? electricWaterPumpTargetRpm; // 电子水泵目标转速 (RPM)
  final double? totalOdometerKm; // 整车真实总里程 (km)
  final double? fuelLevelLiters; // 剩余油量 (L)
  final double? fuelLevelPercent; // 剩余油量百分比 (%)
  final double? fuelRateLitersPerHour; // 瞬时油耗率 (L/h)
  final double? totalFuelConsumedLiters; // 累计总油耗 (L)
  final double? intakeAirTemp; // 进气温度 (°C)
  final double? ambientAirTemp; // 环境温度 (°C)
  final double? catalystTemp; // 三元催化器温度 1 (°C)
  final double? catalystTemp2; // 三元催化器温度 2 (°C)
  final double? throttlePosition; // 节气门开度 (%)
  final double? relativeThrottlePosition; // 相对节气门开度 (%)
  final double? commandedThrottleActuator; // 节气门作动器指令 (%)
  final double? pedalPositionD; // 油门踏板位置 D (%)
  final double? pedalPositionE; // 油门踏板位置 E (%)
  final double? engineLoad; // 发动机负荷 (%)
  final double? mafGramsPerSec; // 进气空气质量流量 (g/s)
  final double? barometricPressureKpa; // 绝对大气压强 (kPa)
  final double? equivalenceRatio; // 空燃比当量比 Lambda
  final double? shortTermFuelTrim; // 短期燃油修正 STFT (%)
  final double? longTermFuelTrim; // 长期燃油修正 LTFT (%)
  final int? runTimeSeconds; // 发动机本次启动运行时间 (s)

  // --- 12V 辅助蓄电池与整车电气 ---
  final double? aux12vVoltage; // 12V 小电池电压 (V)
  final double? aux12vCurrent; // 12V 小电池电流 (A)
  final double? aux12vTemp; // 12V 小电池温度 (°C)
  final double? aux12vSoc; // 12V 小电池电量 (%)
  final int? keyCycles; // 点火启动循环数

  // --- 系统与调试元数据 ---
  final DateTime? lastUpdated;
  final ObdConnectionStatus status;
  final String? statusMessage;
  final String? connectedDeviceName;
  final String? connectedDeviceId;

  const ObdTelemetry({
    this.batterySoc,
    this.batteryVoltage,
    this.batteryCurrent,
    this.batteryPowerKw,
    this.maxCellVoltage,
    this.minCellVoltage,
    this.avgCellVoltage,
    this.cellDeltaVoltage,
    this.batteryTemperatures = const [],
    this.voltageBeforeBoost,
    this.voltageAfterBoost,
    this.mg1InverterTemp,
    this.mg2InverterTemp,
    this.transaxleOilTemp,
    this.mg1Rpm,
    this.mg2Rpm,
    this.mg2Torque,
    this.regenBrakingTorque,
    this.batteryRemainingLife,
    this.speedKmh,
    this.engineRpm,
    this.coolantTemp,
    this.engineOilTemp,
    this.engineOilPressure,
    this.electricWaterPumpRpm,
    this.electricWaterPumpTargetRpm,
    this.totalOdometerKm,
    this.fuelLevelLiters,
    this.fuelLevelPercent,
    this.fuelRateLitersPerHour,
    this.totalFuelConsumedLiters,
    this.intakeAirTemp,
    this.ambientAirTemp,
    this.catalystTemp,
    this.catalystTemp2,
    this.throttlePosition,
    this.relativeThrottlePosition,
    this.commandedThrottleActuator,
    this.pedalPositionD,
    this.pedalPositionE,
    this.engineLoad,
    this.mafGramsPerSec,
    this.barometricPressureKpa,
    this.equivalenceRatio,
    this.shortTermFuelTrim,
    this.longTermFuelTrim,
    this.runTimeSeconds,
    this.aux12vVoltage,
    this.aux12vCurrent,
    this.aux12vTemp,
    this.aux12vSoc,
    this.keyCycles,
    this.lastUpdated,
    this.status = ObdConnectionStatus.disconnected,
    this.statusMessage,
    this.connectedDeviceName,
    this.connectedDeviceId,
  });

  ObdTelemetry copyWith({
    double? batterySoc,
    double? batteryVoltage,
    double? batteryCurrent,
    double? batteryPowerKw,
    double? maxCellVoltage,
    double? minCellVoltage,
    double? avgCellVoltage,
    double? cellDeltaVoltage,
    List<double>? batteryTemperatures,
    double? voltageBeforeBoost,
    double? voltageAfterBoost,
    double? mg1InverterTemp,
    double? mg2InverterTemp,
    double? transaxleOilTemp,
    double? mg1Rpm,
    double? mg2Rpm,
    double? mg2Torque,
    double? regenBrakingTorque,
    double? batteryRemainingLife,
    double? speedKmh,
    double? engineRpm,
    double? coolantTemp,
    double? engineOilTemp,
    double? engineOilPressure,
    double? electricWaterPumpRpm,
    double? electricWaterPumpTargetRpm,
    double? totalOdometerKm,
    double? fuelLevelLiters,
    double? fuelLevelPercent,
    double? fuelRateLitersPerHour,
    double? totalFuelConsumedLiters,
    double? intakeAirTemp,
    double? ambientAirTemp,
    double? catalystTemp,
    double? catalystTemp2,
    double? throttlePosition,
    double? relativeThrottlePosition,
    double? commandedThrottleActuator,
    double? pedalPositionD,
    double? pedalPositionE,
    double? engineLoad,
    double? mafGramsPerSec,
    double? barometricPressureKpa,
    double? equivalenceRatio,
    double? shortTermFuelTrim,
    double? longTermFuelTrim,
    int? runTimeSeconds,
    double? aux12vVoltage,
    double? aux12vCurrent,
    double? aux12vTemp,
    double? aux12vSoc,
    int? keyCycles,
    DateTime? lastUpdated,
    ObdConnectionStatus? status,
    String? statusMessage,
    String? connectedDeviceName,
    String? connectedDeviceId,
  }) {
    return ObdTelemetry(
      batterySoc: batterySoc ?? this.batterySoc,
      batteryVoltage: batteryVoltage ?? this.batteryVoltage,
      batteryCurrent: batteryCurrent ?? this.batteryCurrent,
      batteryPowerKw: batteryPowerKw ?? this.batteryPowerKw,
      maxCellVoltage: maxCellVoltage ?? this.maxCellVoltage,
      minCellVoltage: minCellVoltage ?? this.minCellVoltage,
      avgCellVoltage: avgCellVoltage ?? this.avgCellVoltage,
      cellDeltaVoltage: cellDeltaVoltage ?? this.cellDeltaVoltage,
      batteryTemperatures: batteryTemperatures ?? this.batteryTemperatures,
      voltageBeforeBoost: voltageBeforeBoost ?? this.voltageBeforeBoost,
      voltageAfterBoost: voltageAfterBoost ?? this.voltageAfterBoost,
      mg1InverterTemp: mg1InverterTemp ?? this.mg1InverterTemp,
      mg2InverterTemp: mg2InverterTemp ?? this.mg2InverterTemp,
      transaxleOilTemp: transaxleOilTemp ?? this.transaxleOilTemp,
      mg1Rpm: mg1Rpm ?? this.mg1Rpm,
      mg2Rpm: mg2Rpm ?? this.mg2Rpm,
      mg2Torque: mg2Torque ?? this.mg2Torque,
      regenBrakingTorque: regenBrakingTorque ?? this.regenBrakingTorque,
      batteryRemainingLife: batteryRemainingLife ?? this.batteryRemainingLife,
      speedKmh: speedKmh ?? this.speedKmh,
      engineRpm: engineRpm ?? this.engineRpm,
      coolantTemp: coolantTemp ?? this.coolantTemp,
      engineOilTemp: engineOilTemp ?? this.engineOilTemp,
      engineOilPressure: engineOilPressure ?? this.engineOilPressure,
      electricWaterPumpRpm: electricWaterPumpRpm ?? this.electricWaterPumpRpm,
      electricWaterPumpTargetRpm:
          electricWaterPumpTargetRpm ?? this.electricWaterPumpTargetRpm,
      totalOdometerKm: totalOdometerKm ?? this.totalOdometerKm,
      fuelLevelLiters: fuelLevelLiters ?? this.fuelLevelLiters,
      fuelLevelPercent: fuelLevelPercent ?? this.fuelLevelPercent,
      fuelRateLitersPerHour: fuelRateLitersPerHour ?? this.fuelRateLitersPerHour,
      totalFuelConsumedLiters:
          totalFuelConsumedLiters ?? this.totalFuelConsumedLiters,
      intakeAirTemp: intakeAirTemp ?? this.intakeAirTemp,
      ambientAirTemp: ambientAirTemp ?? this.ambientAirTemp,
      catalystTemp: catalystTemp ?? this.catalystTemp,
      catalystTemp2: catalystTemp2 ?? this.catalystTemp2,
      throttlePosition: throttlePosition ?? this.throttlePosition,
      relativeThrottlePosition:
          relativeThrottlePosition ?? this.relativeThrottlePosition,
      commandedThrottleActuator:
          commandedThrottleActuator ?? this.commandedThrottleActuator,
      pedalPositionD: pedalPositionD ?? this.pedalPositionD,
      pedalPositionE: pedalPositionE ?? this.pedalPositionE,
      engineLoad: engineLoad ?? this.engineLoad,
      mafGramsPerSec: mafGramsPerSec ?? this.mafGramsPerSec,
      barometricPressureKpa:
          barometricPressureKpa ?? this.barometricPressureKpa,
      equivalenceRatio: equivalenceRatio ?? this.equivalenceRatio,
      shortTermFuelTrim: shortTermFuelTrim ?? this.shortTermFuelTrim,
      longTermFuelTrim: longTermFuelTrim ?? this.longTermFuelTrim,
      runTimeSeconds: runTimeSeconds ?? this.runTimeSeconds,
      aux12vVoltage: aux12vVoltage ?? this.aux12vVoltage,
      aux12vCurrent: aux12vCurrent ?? this.aux12vCurrent,
      aux12vTemp: aux12vTemp ?? this.aux12vTemp,
      aux12vSoc: aux12vSoc ?? this.aux12vSoc,
      keyCycles: keyCycles ?? this.keyCycles,
      lastUpdated: lastUpdated ?? this.lastUpdated,
      status: status ?? this.status,
      statusMessage: statusMessage ?? this.statusMessage,
      connectedDeviceName: connectedDeviceName ?? this.connectedDeviceName,
      connectedDeviceId: connectedDeviceId ?? this.connectedDeviceId,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'battery_soc': batterySoc,
      'battery_voltage': batteryVoltage,
      'battery_current': batteryCurrent,
      'battery_power_kw': batteryPowerKw,
      'max_cell_voltage': maxCellVoltage,
      'min_cell_voltage': minCellVoltage,
      'avg_cell_voltage': avgCellVoltage,
      'cell_delta_voltage': cellDeltaVoltage,
      'battery_temperatures': batteryTemperatures,
      'voltage_before_boost': voltageBeforeBoost,
      'voltage_after_boost': voltageAfterBoost,
      'mg1_inverter_temp': mg1InverterTemp,
      'mg2_inverter_temp': mg2InverterTemp,
      'transaxle_oil_temp': transaxleOilTemp,
      'mg1_rpm': mg1Rpm,
      'mg2_rpm': mg2Rpm,
      'mg2_torque': mg2Torque,
      'regen_braking_torque': regenBrakingTorque,
      'speed_kmh': speedKmh,
      'engine_rpm': engineRpm,
      'coolant_temp': coolantTemp,
      'engine_oil_temp': engineOilTemp,
      'electric_water_pump_rpm': electricWaterPumpRpm,
      'electric_water_pump_target_rpm': electricWaterPumpTargetRpm,
      'total_odometer_km': totalOdometerKm,
      'fuel_level_liters': fuelLevelLiters,
      'fuel_rate_l_h': fuelRateLitersPerHour,
      'intake_air_temp': intakeAirTemp,
      'ambient_air_temp': ambientAirTemp,
      'catalyst_temp': catalystTemp,
      'catalyst_temp2': catalystTemp2,
      'throttle_position': throttlePosition,
      'pedal_position_d': pedalPositionD,
      'pedal_position_e': pedalPositionE,
      'engine_load': engineLoad,
      'maf_g_s': mafGramsPerSec,
      'baro_kpa': barometricPressureKpa,
      'aux_12v_voltage': aux12vVoltage,
      'aux_12v_current': aux12vCurrent,
      'status': status.name,
      'last_updated': lastUpdated?.toIso8601String(),
    };
  }
}
