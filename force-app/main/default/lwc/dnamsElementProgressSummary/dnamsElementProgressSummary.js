import { LightningElement, api, wire } from "lwc";
import { getRecord } from "lightning/uiRecordApi";
import { refreshApex } from "@salesforce/apex";
import getElementProgress from "@salesforce/apex/DNAMS_PackageInsightsController.getElementProgress";
import LAST_MODIFIED from "@salesforce/schema/DNAMS_Package__c.LastModifiedDate";

/** Element Progress tab header: a pass/fail line per pipeline stage. */
export default class DnamsElementProgressSummary extends LightningElement {
    @api recordId;
    progress;
    error;
    wiredResult;
    lastModified;

    @wire(getElementProgress, { packageId: "$recordId" })
    wiredProgress(result) {
        this.wiredResult = result;
        this.progress = result.data;
        this.error = result.error ? (result.error.body?.message || "Progress could not be loaded.") : undefined;
    }

    @wire(getRecord, { recordId: "$recordId", fields: [LAST_MODIFIED] })
    wiredRecord({ data }) {
        const stamp = data?.fields?.LastModifiedDate?.value;
        if (stamp && this.lastModified && stamp !== this.lastModified) {
            this.handleRefresh();
        }
        this.lastModified = stamp || this.lastModified;
    }

    get stages() {
        return (this.progress?.stages || []).map((stage) => {
            const reviewed = stage.passed + stage.failed;
            return {
                key: stage.stage,
                name: stage.label || stage.stage,
                passed: stage.passed,
                failed: stage.failed,
                notRun: stage.notRun,
                passWidth: `width:${reviewed ? (stage.passed / reviewed) * 100 : 0}%`,
                failWidth: `width:${reviewed ? (stage.failed / reviewed) * 100 : 0}%`,
                hasResults: reviewed > 0
            };
        });
    }

    get passRateLabel() {
        const rate = this.progress?.passRate;
        return rate === null || rate === undefined ? null : `Rule pass rate ${rate}%`;
    }

    handleRefresh() {
        return refreshApex(this.wiredResult);
    }
}
