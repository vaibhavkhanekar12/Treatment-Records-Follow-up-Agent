import { createElement } from 'lwc';
import TreatmentRecordsFollowUpConsole from 'c/treatmentRecordsFollowUpConsole';
import getQueue from '@salesforce/apex/FollowUpWorkQueueController.getQueue';
import getDetail from '@salesforce/apex/FollowUpWorkQueueController.getDetail';
import getPermissions from '@salesforce/apex/FollowUpWorkQueueController.getPermissions';
import approve from '@salesforce/apex/FollowUpWorkQueueController.approve';
import send from '@salesforce/apex/FollowUpWorkQueueController.send';
import reject from '@salesforce/apex/FollowUpWorkQueueController.reject';
import bulkApprove from '@salesforce/apex/FollowUpWorkQueueController.bulkApprove';

jest.mock('@salesforce/apex/FollowUpWorkQueueController.getQueue', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/FollowUpWorkQueueController.getDetail', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/FollowUpWorkQueueController.getPermissions', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/FollowUpWorkQueueController.approve', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/FollowUpWorkQueueController.bulkApprove', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/FollowUpWorkQueueController.saveDraft', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/FollowUpWorkQueueController.reject', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/FollowUpWorkQueueController.overrideRecommendation', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/FollowUpWorkQueueController.complete', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/FollowUpWorkQueueController.send', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/FollowUpWorkQueueController.regenerateDraft', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/FollowUpWorkQueueController.logResponse', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/FollowUpWorkQueueController.suggestClassification', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/FollowUpWorkQueueController.evaluateMatter', () => ({ default: jest.fn() }), { virtual: true });

const PENDING_ROW = {
    id: 'a01000000000001AAA',
    name: 'FUR-000001',
    matterName: 'M-1001',
    typeLabel: 'Client Check-In',
    priority: 'High',
    status: 'Pending_Review',
    audience: 'Client',
    channel: 'Email',
    gapDays: 30,
    reason: 'Last recorded treatment: 8/1/2026 (30 days ago).',
    draftSource: 'Template',
    external: true
};

const DETAIL = {
    item: PENDING_ROW,
    draftSubject: 'Checking in on your care',
    draftMessage: 'Hi Jamie, are you still receiving treatment?',
    rationale: 'Raised by the configured follow-up rule.',
    matterFacts: 'Matter: M-1001',
    history: 'No follow-up history.'
};

// eslint-disable-next-line @lwc/lwc/no-async-operation
const flushPromises = () => new Promise((resolve) => setTimeout(resolve, 0));

async function mount(props = {}) {
    const element = createElement('c-treatment-records-follow-up-console', { is: TreatmentRecordsFollowUpConsole });
    Object.assign(element, props);
    document.body.appendChild(element);
    await flushPromises();
    return element;
}

async function openDetail(element) {
    const table = element.shadowRoot.querySelector('lightning-datatable');
    table.dispatchEvent(new CustomEvent('rowaction', { detail: { action: { name: 'review' }, row: PENDING_ROW } }));
    await flushPromises();
}

function button(element, dataId) {
    return element.shadowRoot.querySelector(`lightning-button[data-id="${dataId}"]`);
}

describe('c-treatment-records-follow-up-console', () => {
    beforeEach(() => {
        getPermissions.mockResolvedValue({ canApprove: true, canSend: true, canBulkApprove: true, canOverride: true });
        getQueue.mockResolvedValue([PENDING_ROW]);
        getDetail.mockResolvedValue(DETAIL);
        approve.mockResolvedValue(undefined);
        reject.mockResolvedValue(undefined);
        bulkApprove.mockResolvedValue(undefined);
        send.mockResolvedValue({ sent: 1, failed: 0, errors: [] });
    });

    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('loads the open queue for the current user context', async () => {
        const element = await mount();

        expect(getQueue).toHaveBeenCalledWith({
            statusFilter: 'Open',
            priority: null,
            recommendationType: null,
            onlyMine: false,
            matterId: null
        });
        const table = element.shadowRoot.querySelector('lightning-datatable');
        expect(table.data).toHaveLength(1);
    });

    it('filters by matter when placed on a Matter record page', async () => {
        await mount({ recordId: 'a00000000000001AAA' });
        expect(getQueue.mock.calls[0][0].matterId).toBe('a00000000000001AAA');
    });

    it('shows facts, rationale and draft for review', async () => {
        const element = await mount();
        await openDetail(element);

        expect(getDetail).toHaveBeenCalledWith({ recommendationId: PENDING_ROW.id });
        const detail = element.shadowRoot.querySelector('section[data-id="detail"]');
        expect(detail.textContent).toContain('Last recorded treatment');
        expect(detail.textContent).toContain('Raised by the configured follow-up rule.');
        const message = element.shadowRoot.querySelector('lightning-textarea[data-id="message"]');
        expect(message.value).toBe(DETAIL.draftMessage);
    });

    it('does not allow sending a pending (unapproved) client message', async () => {
        const element = await mount();
        await openDetail(element);

        expect(button(element, 'send').disabled).toBe(true);
        expect(button(element, 'approve').disabled).toBe(false);
    });

    it('approves with the edited draft', async () => {
        const element = await mount();
        await openDetail(element);
        const message = element.shadowRoot.querySelector('lightning-textarea[data-id="message"]');
        message.value = 'Edited message';
        message.dispatchEvent(new CustomEvent('change'));

        button(element, 'approve').click();
        await flushPromises();

        expect(approve).toHaveBeenCalledWith({
            recommendationId: PENDING_ROW.id,
            subject: DETAIL.draftSubject,
            message: 'Edited message'
        });
    });

    it('enables send once approved', async () => {
        getDetail.mockResolvedValue({ ...DETAIL, item: { ...PENDING_ROW, status: 'Approved' }, approvedByName: 'Casey Manager' });
        const element = await mount();
        await openDetail(element);

        expect(button(element, 'send').disabled).toBe(false);
        button(element, 'send').click();
        await flushPromises();
        expect(send).toHaveBeenCalledWith({ recommendationIds: [PENDING_ROW.id] });
    });

    it('hides approve/send capability for users without permissions', async () => {
        getPermissions.mockResolvedValue({ canApprove: false, canSend: false, canBulkApprove: false, canOverride: false });
        const element = await mount();
        await openDetail(element);

        expect(button(element, 'approve').disabled).toBe(true);
        expect(button(element, 'send').disabled).toBe(true);
        expect(button(element, 'override').disabled).toBe(true);
        expect(button(element, 'bulk-approve').disabled).toBe(true);
    });

    it('rejects with a reason', async () => {
        const element = await mount();
        await openDetail(element);
        button(element, 'reject').click();
        await flushPromises();

        const reason = element.shadowRoot.querySelector('lightning-textarea[data-field="rejectReason"]');
        reason.value = 'Already spoke with client';
        reason.dispatchEvent(new CustomEvent('change'));
        button(element, 'confirm-reject').click();
        await flushPromises();

        expect(reject).toHaveBeenCalledWith({ recommendationId: PENDING_ROW.id, reason: 'Already spoke with client' });
    });

    it('bulk approves selected rows', async () => {
        const element = await mount();
        const table = element.shadowRoot.querySelector('lightning-datatable');
        table.dispatchEvent(new CustomEvent('rowselection', { detail: { selectedRows: [PENDING_ROW] } }));
        await flushPromises();

        expect(button(element, 'bulk-approve').disabled).toBe(false);
        button(element, 'bulk-approve').click();
        await flushPromises();
        expect(bulkApprove).toHaveBeenCalledWith({ recommendationIds: [PENDING_ROW.id] });
    });

    it('shows server errors instead of the table', async () => {
        getQueue.mockRejectedValue({ body: { message: 'Insufficient access' } });
        const element = await mount();

        expect(element.shadowRoot.querySelector('[role="alert"]').textContent).toBe('Insufficient access');
    });
});
