import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getQueue from '@salesforce/apex/FollowUpWorkQueueController.getQueue';
import getDetail from '@salesforce/apex/FollowUpWorkQueueController.getDetail';
import getPermissions from '@salesforce/apex/FollowUpWorkQueueController.getPermissions';
import approve from '@salesforce/apex/FollowUpWorkQueueController.approve';
import bulkApprove from '@salesforce/apex/FollowUpWorkQueueController.bulkApprove';
import saveDraft from '@salesforce/apex/FollowUpWorkQueueController.saveDraft';
import reject from '@salesforce/apex/FollowUpWorkQueueController.reject';
import overrideRecommendation from '@salesforce/apex/FollowUpWorkQueueController.overrideRecommendation';
import complete from '@salesforce/apex/FollowUpWorkQueueController.complete';
import send from '@salesforce/apex/FollowUpWorkQueueController.send';
import regenerateDraft from '@salesforce/apex/FollowUpWorkQueueController.regenerateDraft';
import logResponse from '@salesforce/apex/FollowUpWorkQueueController.logResponse';
import suggestClassification from '@salesforce/apex/FollowUpWorkQueueController.suggestClassification';
import evaluateMatter from '@salesforce/apex/FollowUpWorkQueueController.evaluateMatter';

const OPEN_STATUSES = ['Pending_Review', 'Approved', 'Send_Failed'];

const COLUMNS = [
    { label: 'Recommendation', fieldName: 'name', initialWidth: 130 },
    { label: 'Matter', fieldName: 'matterName', initialWidth: 120 },
    { label: 'Type', fieldName: 'typeLabel' },
    { label: 'Priority', fieldName: 'priority', initialWidth: 90 },
    { label: 'Status', fieldName: 'status', initialWidth: 120 },
    { label: 'Audience', fieldName: 'audience', initialWidth: 95 },
    { label: 'Channel', fieldName: 'channel', initialWidth: 90 },
    { label: 'Gap Days', fieldName: 'gapDays', type: 'number', initialWidth: 90 },
    { label: 'Records Age', fieldName: 'recordsAgeDays', type: 'number', initialWidth: 105 },
    { label: 'Prior Follow-ups', fieldName: 'priorFollowUps', type: 'number', initialWidth: 125 },
    { label: 'Provider', fieldName: 'providerName' },
    { label: 'Assigned To', fieldName: 'assignedToName' },
    { type: 'action', typeAttributes: { rowActions: [{ label: 'Review', name: 'review' }] } }
];

export default class TreatmentRecordsFollowUpConsole extends LightningElement {
    /** Matter Id when placed on a Matter record page. */
    @api recordId;

    columns = COLUMNS;
    rows = [];
    selectedIds = [];
    permissions = {};
    detail;
    isLoading = false;
    error;

    statusFilter = 'Open';
    priorityFilter = '';
    typeFilter = '';
    onlyMine = false;

    // editable draft + forms
    draftSubject;
    draftMessage;
    rejectReason = '';
    overrideReason = '';
    snoozeUntil;
    overridePriority = '';
    responseText = '';
    responseSource = 'Phone';
    responseCategory = '';
    activePanel;

    statusOptions = [
        { label: 'Open (needs action)', value: 'Open' },
        { label: 'Pending Review', value: 'Pending_Review' },
        { label: 'Approved (ready to send)', value: 'Approved' },
        { label: 'Send Failed', value: 'Send_Failed' },
        { label: 'Sent - awaiting response', value: 'Awaiting_Response' },
        { label: 'Closed', value: 'Closed' }
    ];

    priorityOptions = [
        { label: 'All priorities', value: '' },
        { label: 'High', value: 'High' },
        { label: 'Medium', value: 'Medium' },
        { label: 'Low', value: 'Low' }
    ];

    typeOptions = [
        { label: 'All types', value: '' },
        { label: 'Client Check-In', value: 'Client_Check_In' },
        { label: 'Treatment Gap Review', value: 'Treatment_Gap_Review' },
        { label: 'Provider Records Follow-up', value: 'Provider_Follow_Up' },
        { label: 'Provider Escalation', value: 'Provider_Escalation' },
        { label: 'Missing Bills', value: 'Missing_Bills' },
        { label: 'Stalled Matter Review', value: 'Stalled_Matter_Review' },
        { label: 'Client Status Update', value: 'Client_Status_Update' },
        { label: 'Inbound Response Review', value: 'Inbound_Response_Review' },
        { label: 'Case Manager Escalation', value: 'Case_Manager_Escalation' }
    ];

    sourceOptions = [
        { label: 'Phone', value: 'Phone' },
        { label: 'Email', value: 'Email' },
        { label: 'SMS', value: 'SMS' },
        { label: 'Fax', value: 'Fax' },
        { label: 'Portal', value: 'Portal' }
    ];

    categoryOptions = [
        { label: 'Treatment Continuing', value: 'Treatment_Continuing' },
        { label: 'Treatment Stopped', value: 'Treatment_Stopped' },
        { label: 'Records Sent', value: 'Records_Sent' },
        { label: 'Provider Action Required', value: 'Provider_Action_Required' },
        { label: 'Callback Requested', value: 'Callback_Requested' },
        { label: 'Status Question', value: 'Status_Question' },
        { label: 'Opt-Out Request', value: 'Opt_Out' },
        { label: 'Unclear', value: 'Unclear' }
    ];

    overridePriorityOptions = [
        { label: 'No change', value: '' },
        { label: 'High', value: 'High' },
        { label: 'Medium', value: 'Medium' },
        { label: 'Low', value: 'Low' }
    ];

    connectedCallback() {
        this.loadPermissions();
        this.loadQueue();
    }

    // ------------------------------------------------------------------ getters

    get hasRows() {
        return this.rows.length > 0;
    }

    get rowCountLabel() {
        return `${this.rows.length} recommendation${this.rows.length === 1 ? '' : 's'}`;
    }

    get isRecordPage() {
        return !!this.recordId;
    }

    get noSelection() {
        return this.selectedIds.length === 0;
    }

    get item() {
        return this.detail ? this.detail.item : undefined;
    }

    get isOpen() {
        return !!this.item && OPEN_STATUSES.includes(this.item.status);
    }

    get isExternal() {
        return !!this.item && this.item.external;
    }

    get showDraft() {
        return this.isExternal;
    }

    get draftReadOnly() {
        return !this.isOpen;
    }

    get canApproveThis() {
        return this.permissions.canApprove && this.isExternal && this.item.status === 'Pending_Review';
    }

    get cannotApproveThis() {
        return !this.canApproveThis;
    }

    get canSendThis() {
        if (!this.permissions.canSend || !this.item) {
            return false;
        }
        return this.isExternal ? ['Approved', 'Send_Failed'].includes(this.item.status) : this.isOpen;
    }

    get cannotSendThis() {
        return !this.canSendThis;
    }

    get sendLabel() {
        return this.isExternal ? 'Send' : 'Create Task';
    }

    get notOpen() {
        return !this.isOpen;
    }

    get cannotOverride() {
        return !this.permissions.canOverride || !this.isOpen;
    }

    get cannotComplete() {
        if (!this.item) {
            return true;
        }
        return !(this.isOpen || this.item.status === 'Sent');
    }

    get cannotBulkApprove() {
        return !this.permissions.canBulkApprove || this.noSelection;
    }

    get cannotBulkSend() {
        return !this.permissions.canSend || this.noSelection;
    }

    get showRejectPanel() {
        return this.activePanel === 'reject';
    }

    get showOverridePanel() {
        return this.activePanel === 'override';
    }

    get showResponsePanel() {
        return this.activePanel === 'response';
    }

    get approvalSummary() {
        if (!this.detail || !this.detail.approvedByName) {
            return null;
        }
        return `Approved by ${this.detail.approvedByName}`;
    }

    // ------------------------------------------------------------------ data

    async loadPermissions() {
        try {
            this.permissions = (await getPermissions()) || {};
        } catch (e) {
            this.permissions = {};
        }
    }

    async loadQueue() {
        this.isLoading = true;
        this.error = undefined;
        try {
            this.rows = await getQueue({
                statusFilter: this.statusFilter,
                priority: this.priorityFilter || null,
                recommendationType: this.typeFilter || null,
                onlyMine: this.onlyMine,
                matterId: this.recordId || null
            });
            this.selectedIds = [];
        } catch (e) {
            this.error = this.messageOf(e);
            this.rows = [];
        } finally {
            this.isLoading = false;
        }
    }

    async openDetail(recommendationId) {
        this.isLoading = true;
        try {
            this.detail = await getDetail({ recommendationId });
            this.draftSubject = this.detail.draftSubject;
            this.draftMessage = this.detail.draftMessage;
            this.resetForms();
        } catch (e) {
            this.toast('Could not load recommendation', this.messageOf(e), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    // ------------------------------------------------------------------ handlers: filters and table

    handleStatusFilter(event) {
        this.statusFilter = event.detail.value;
        this.loadQueue();
    }

    handlePriorityFilter(event) {
        this.priorityFilter = event.detail.value;
        this.loadQueue();
    }

    handleTypeFilter(event) {
        this.typeFilter = event.detail.value;
        this.loadQueue();
    }

    handleMineToggle(event) {
        this.onlyMine = event.target.checked;
        this.loadQueue();
    }

    handleRefresh() {
        this.loadQueue();
    }

    handleRowSelection(event) {
        this.selectedIds = event.detail.selectedRows.map((row) => row.id);
    }

    handleRowAction(event) {
        this.openDetail(event.detail.row.id);
    }

    handleCloseDetail() {
        this.detail = undefined;
    }

    async handleEvaluateMatter() {
        await this.run(async () => {
            const created = await evaluateMatter({ matterId: this.recordId });
            return `${created} new recommendation(s) created.`;
        });
    }

    // ------------------------------------------------------------------ handlers: detail actions

    handleSubjectChange(event) {
        this.draftSubject = event.target.value;
    }

    handleMessageChange(event) {
        this.draftMessage = event.target.value;
    }

    async handleSaveDraft() {
        await this.run(async () => {
            await saveDraft({ recommendationId: this.item.id, subject: this.draftSubject, message: this.draftMessage });
            return 'Draft saved. Edited drafts need approval again.';
        });
    }

    async handleApprove() {
        await this.run(async () => {
            await approve({ recommendationId: this.item.id, subject: this.draftSubject, message: this.draftMessage });
            return 'Approved. The message has not been sent yet.';
        });
    }

    async handleSend() {
        await this.run(async () => {
            const outcome = await send({ recommendationIds: [this.item.id] });
            if (outcome.failed > 0) {
                throw new Error(outcome.errors.join('; '));
            }
            return this.isExternal ? 'Sent.' : 'Task created and assigned.';
        });
    }

    async handleRegenerate() {
        await this.run(async () => {
            await regenerateDraft({ recommendationId: this.item.id });
            return 'Draft regenerated from current facts. Review before approving.';
        });
    }

    async handleComplete() {
        await this.run(async () => {
            await complete({ recommendationId: this.item.id });
            return 'Marked complete.';
        });
    }

    handleShowReject() {
        this.activePanel = 'reject';
    }

    handleShowOverride() {
        this.activePanel = 'override';
    }

    handleShowResponse() {
        this.activePanel = 'response';
    }

    handleCancelPanel() {
        this.resetForms();
    }

    handleFormChange(event) {
        const field = event.target.dataset.field;
        this[field] = event.detail && event.detail.value !== undefined ? event.detail.value : event.target.value;
    }

    async handleConfirmReject() {
        await this.run(async () => {
            await reject({ recommendationId: this.item.id, reason: this.rejectReason });
            return 'Recommendation rejected.';
        });
    }

    async handleConfirmOverride() {
        await this.run(async () => {
            await overrideRecommendation({
                recommendationId: this.item.id,
                reason: this.overrideReason,
                snoozeUntil: this.snoozeUntil || null,
                priority: this.overridePriority || null
            });
            return 'Override saved.';
        });
    }

    async handleSuggestCategory() {
        try {
            const suggestion = await suggestClassification({
                responseText: this.responseText,
                audience: this.item ? this.item.audience : null
            });
            this.responseCategory = suggestion.category;
        } catch (e) {
            this.toast('Suggestion unavailable', this.messageOf(e), 'warning');
        }
    }

    async handleConfirmResponse() {
        await this.run(async () => {
            const result = await logResponse({
                recommendationId: this.item.id,
                responseText: this.responseText,
                category: this.responseCategory || null,
                source: this.responseSource
            });
            return result.reviewCreated
                ? 'Response logged. A case manager review item was created.'
                : `Response logged (${result.category}).`;
        });
    }

    async handleBulkApprove() {
        await this.run(async () => {
            await bulkApprove({ recommendationIds: this.selectedIds });
            return `${this.selectedIds.length} template draft(s) approved.`;
        }, false);
    }

    async handleBulkSend() {
        await this.run(async () => {
            const outcome = await send({ recommendationIds: this.selectedIds });
            if (outcome.failed > 0) {
                this.toast('Some items were not sent', outcome.errors.join('; '), 'warning');
            }
            return `${outcome.sent} sent, ${outcome.failed} failed.`;
        }, false);
    }

    // ------------------------------------------------------------------ helpers

    /** Runs an action, shows the result, then refreshes the queue (and the open detail). */
    async run(action, refreshDetail = true) {
        this.isLoading = true;
        try {
            const message = await action();
            this.toast('Success', message, 'success');
            const currentId = this.item ? this.item.id : null;
            await this.loadQueue();
            if (refreshDetail && currentId) {
                await this.openDetail(currentId);
            }
        } catch (e) {
            this.toast('Action not completed', this.messageOf(e), 'error');
        } finally {
            this.isLoading = false;
        }
    }

    resetForms() {
        this.activePanel = undefined;
        this.rejectReason = '';
        this.overrideReason = '';
        this.snoozeUntil = undefined;
        this.overridePriority = '';
        this.responseText = '';
        this.responseSource = 'Phone';
        this.responseCategory = '';
    }

    messageOf(error) {
        if (!error) {
            return 'Unknown error';
        }
        if (error.body && error.body.message) {
            return error.body.message;
        }
        return error.message || JSON.stringify(error);
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
