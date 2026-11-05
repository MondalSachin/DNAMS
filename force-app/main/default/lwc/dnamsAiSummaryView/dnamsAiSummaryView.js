import { LightningElement, api } from "lwc";

const HEALTH = {
    GREEN: { label: "Green", tone: "green" },
    AMBER: { label: "Amber", tone: "amber" },
    RED: { label: "Red", tone: "red" }
};
const STATUS = {
    FAILED: { label: "Failed", tone: "red" },
    MISSING: { label: "Missing", tone: "red" },
    NEEDS_REVIEW: { label: "Needs review", tone: "amber" },
    PASSED: { label: "Passed", tone: "green" }
};

/**
 * Structured AI summary: health banner, headline, summary, one card per element that needs attention and next steps.
 * audience "dealer" hides the RMR next steps; the AI label is always shown.
 */
export default class DnamsAiSummaryView extends LightningElement {
    @api summaryJson;
    @api plainText;
    @api health;
    @api aiLabel;
    @api audience = "rmr";

    get summary() {
        if (!this.summaryJson) {
            return null;
        }
        try {
            return JSON.parse(this.summaryJson);
        } catch (e) {
            return null;
        }
    }

    get hasSummary() {
        return this.summary !== null;
    }

    get healthInfo() {
        const key = String(this.health || this.summary?.overall_health || "").toUpperCase();
        return HEALTH[key] || { label: "Not reviewed", tone: "neutral" };
    }

    get bannerClass() {
        return `banner banner_${this.healthInfo.tone}`;
    }

    get headline() {
        return this.summary?.headline;
    }

    get elements() {
        return (this.summary?.elements || []).map((item, index) => {
            const status = STATUS[String(item.status || "").toUpperCase()] || STATUS.NEEDS_REVIEW;
            return {
                key: `${index}-${item.element}`,
                name: item.element,
                statusLabel: status.label,
                chipClass: `chip chip_${status.tone}`,
                cardClass: `element element_${status.tone}`,
                findings: (item.findings || []).map((text, i) => ({ key: `${index}-${i}`, text }))
            };
        });
    }

    get hasElements() {
        return this.elements.length > 0;
    }

    get nextSteps() {
        return (this.summary?.next_steps || []).map((text, i) => ({ key: `step-${i}`, text, number: i + 1 }));
    }

    get showNextSteps() {
        return this.audience !== "dealer" && this.nextSteps.length > 0;
    }
}
