import { LightningElement } from "lwc";
import LOGO from "@salesforce/resourceUrl/HarborMotorsLogo";

/**
 * Harbor Motors brand bar at the top of the dealer portal (demo brand; no data, safe for site guests).
 */
export default class DnamsBrandHeader extends LightningElement {
  logoUrl = LOGO;
}
