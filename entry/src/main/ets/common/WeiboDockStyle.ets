import { HdsTabsFloatingStyle, hdsMaterial } from '@kit.UIDesignKit';

/** Shared native dock material. Keep gradientMask unset to use HDS's own
 * light/dark gradient backplate, including the area below the floating bar. */
export function createWeiboDockStyle(level: number, lightColor: ResourceColor,
  width?: number): HdsTabsFloatingStyle {
  let materialLevel: hdsMaterial.MaterialLevel = hdsMaterial.MaterialLevel.ADAPTIVE;
  if (level === 0) {
    materialLevel = hdsMaterial.MaterialLevel.EXQUISITE;
  } else if (level === 1) {
    materialLevel = hdsMaterial.MaterialLevel.GENTLE;
  } else if (level === 2) {
    materialLevel = hdsMaterial.MaterialLevel.SMOOTH;
  }
  return {
    adaptToHandedness: true,
    barBottomMargin: 30,
    lightColor: lightColor,
    barWidth: width === undefined ? undefined : {
      smallWidth: width, mediumWidth: width, largeWidth: width
    },
    systemMaterialEffect: {
      materialType: hdsMaterial.MaterialType.IMMERSIVE,
      materialLevel: materialLevel
    }
  };
}
