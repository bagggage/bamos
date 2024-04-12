#include "task.h"

#include "assert.h"

#include "cpu/feature.h"

#include "math.h"
#include "mem.h"

static CpuTaskList task_list = { NULL, { 0 } };
static uint32_t cpus_count = 0;

static inline bool_t tsk_is_foreach(const CpuTaskNode* task) {
    return ((task->bitfield & (1ull << 63)) != 0) ? TRUE : FALSE;
}

bool_t tsk_push(CpuTaskHandler task, void* parameters, const bool_t is_foreach) {
    spin_lock(&task_list.lock);

    CpuTaskNode* new_node = (CpuTaskNode*)kmalloc(sizeof(CpuTaskNode));

    if (new_node == NULL) {
        spin_release(&task_list.lock);
        return FALSE;
    }

    new_node->handler = task;
    new_node->parameters = parameters;
    new_node->next = task_list.next;
    task_list.next = new_node;

    if (is_foreach == TRUE) {
        new_node->bitfield = (1ull << 63);
    }
    else {
        new_node->bitfield = 0;
    }

    spin_release(&task_list.lock);

    return TRUE;
}

void tsk_remove(CpuTaskNode* task) {
    spin_lock(&task_list.lock);

    CpuTaskNode* prev = NULL;
    CpuTaskNode* node = task_list.next;

    while (node != NULL && node != task) {
        prev = node;
        node = node->next;
    }

    if (node == NULL) {
        spin_release(&task_list.lock);
        kassert(FALSE);

        return;
    }

    if (prev != NULL) {
        prev->next = node->next;
    }
    else {
        task_list.next = node->next;
    }

    spin_release(&task_list.lock);

    kfree(node->parameters);
    kfree((void*)node);
}

CpuTaskNode* tsk_get(const uint32_t cpu_idx) {
    const uint64_t bit_mask = (1ull << cpu_idx);

    CpuTaskNode* prev = NULL;
    CpuTaskNode* task = task_list.next;

    while (task != NULL) {
        if (tsk_is_foreach(task) == FALSE) break;

        if (cpu_idx >= 63 || (task->bitfield & bit_mask) != 0) {
            prev = task;
            task = task->next;
        }

        return task;
    }

    if (task == NULL) return task;

    if (prev == NULL) {
        task_list.next = task->next;
    }
    else {
        prev->next = task->next;
    }

    return task;
}

void tsk_complete_foreach_task(CpuTaskNode* task, const uint32_t cpu_idx) {
    spin_lock(&task->mutilock);

    task->bitfield |= (1ull << cpu_idx);

    if (popcount(task->bitfield) == cpus_count + 1) {
        spin_release(&task->mutilock);
        tsk_remove(task);
    }
    else {
        spin_release(&task->mutilock);
    }
}

void tsk_exec() {
    const uint32_t cpu_idx = cpu_get_idx();

    wait:
    //while (task_list.next == NULL);

    spin_lock(&task_list.lock);

    if (task_list.next == NULL) {
        spin_release(&task_list.lock);
        goto wait;
    }

    CpuTaskNode* task = tsk_get(cpu_idx);

    spin_release(&task_list.lock);

    if (task == NULL) goto wait;

    task->handler(task->parameters);

    if (tsk_is_foreach(task)) {
        tsk_complete_foreach_task(task, cpu_idx);
    }
    else {
        kfree(task->parameters);
        kfree((void*)task);
    }
}