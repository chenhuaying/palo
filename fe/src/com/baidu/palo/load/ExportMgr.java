// Copyright (c) 2017, Baidu.com, Inc. All Rights Reserved

// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

package com.baidu.palo.load;

import com.baidu.palo.analysis.BrokerDesc;
import com.baidu.palo.analysis.ExportStmt;
import com.baidu.palo.catalog.Catalog;
import com.baidu.palo.catalog.Database;
import com.baidu.palo.catalog.Table;
import com.baidu.palo.common.Config;
import com.baidu.palo.common.util.ListComparator;
import com.baidu.palo.common.util.OrderByPair;
import com.baidu.palo.common.util.TimeUtils;

import com.google.common.base.Joiner;
import com.google.common.base.Preconditions;
import com.google.common.base.Strings;
import com.google.common.collect.Lists;
import com.google.common.collect.Maps;

import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;

import java.util.ArrayList;
import java.util.Collections;
import java.util.Iterator;
import java.util.LinkedList;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.locks.ReentrantReadWriteLock;

public class ExportMgr {
    private static final Logger LOG = LogManager.getLogger(ExportJob.class);

    // lock for export job
    // lock is private and must use after db lock
    private ReentrantReadWriteLock lock;

    private Map<Long, ExportJob> idToJob; // exportJobId to exportJob

    public ExportMgr() {
        idToJob = Maps.newHashMap();
        lock = new ReentrantReadWriteLock(true);
    }

    public void readLock() {
        lock.readLock().lock();
    }

    public void readUnlock() {
        lock.readLock().unlock();
    }

    private void writeLock() {
        lock.writeLock().lock();
    }

    private void writeUnlock() {
        lock.writeLock().unlock();
    }

    public Map<Long, ExportJob> getIdToJob() {
        return idToJob;
    }

    public void addExportJob(ExportStmt stmt) throws Exception {
        long jobId = Catalog.getInstance().getNextId();
        ExportJob job = createJob(jobId, stmt);
        writeLock();
        try {
            unprotectAddJob(job);
            Catalog.getInstance().getEditLog().logExportCreate(job);
        } finally {
            writeUnlock();
        }
        LOG.debug("debug: add export job. {}", job);
    }

    public void unprotectAddJob(ExportJob job) {
        idToJob.put(job.getId(), job);
    }

    private ExportJob createJob(long jobId, ExportStmt stmt) throws Exception {
        ExportJob job = new ExportJob(jobId);
        job.setJob(stmt);
        return job;
    }

    public List<ExportJob> getExportJobs(ExportJob.JobState state) {
        List<ExportJob> result = Lists.newArrayList();
        readLock();
        try {
            for (ExportJob job : idToJob.values()) {
                if (job.getState() == state) {
                    result.add(job);
                }
            }
        } finally {
            readUnlock();
        }

        return result;
    }

    // NOTE: jobid and states may both specified, or only one of them, or neither
    public LinkedList<List<Comparable>> getExportJobInfosByIdOrState(
            long dbId, long jobId, Set<ExportJob.JobState> states,
            ArrayList<OrderByPair> orderByPairs) {

        LinkedList<List<Comparable>> exportJobInfos = new LinkedList<List<Comparable>>();

        readLock();
        try {
            for (ExportJob job : idToJob.values()) {
                long id = job.getId();
                ExportJob.JobState state = job.getState();

                if (job.getDbId() != dbId) {
                    continue;
                }

                if (jobId != 0) {
                    if (id != jobId) {
                        continue;
                    }
                }

                if (states != null) {
                    if (!states.contains(state)) {
                        continue;
                    }
                }

                List<Comparable> jobInfo = new ArrayList<Comparable>();
                // add slot in order
                jobInfo.add(id);
                jobInfo.add(state.name());
                jobInfo.add(job.getProgress() + "%");
                // task infos
                StringBuilder sb = new StringBuilder();
                sb.append(" PARTITION:");
                List<String> partitions = job.getPartitions();
                if (partitions == null) {
                    sb.append("ALL");
                } else {
                    Joiner.on(",").appendTo(sb, partitions);
                }
                sb.append("; ");

                BrokerDesc brokerDesc = job.getBrokerDesc();
                if (brokerDesc != null) {
                    sb.append("BROKER:").append(brokerDesc.getName());
                }
                jobInfo.add(sb.toString());

                sb.append("PATH:").append(job.getExportPath());

                // error msg
                if (job.getState() == ExportJob.JobState.CANCELLED) {
                    ExportFailMsg failMsg = job.getFailMsg();
                    jobInfo.add("type:" + failMsg.getCancelType() + "; msg:" + failMsg.getMsg());
                } else {
                    jobInfo.add("N/A");
                }

                jobInfo.add(TimeUtils.longToTimeString(job.getCreateTimeMs()));
                jobInfo.add(TimeUtils.longToTimeString(job.getStartTimeMs()));
                jobInfo.add(TimeUtils.longToTimeString(job.getFinishTimeMs()));
                jobInfo.add(job.getExportPath());

                exportJobInfos.add(jobInfo);
            }
        } finally {
            readUnlock();
        }

        // order by
        ListComparator<List<Comparable>> comparator = null;
        if (orderByPairs != null) {
            OrderByPair[] orderByPairArr = new OrderByPair[orderByPairs.size()];
            comparator = new ListComparator<List<Comparable>>(orderByPairs.toArray(orderByPairArr));
        } else {
            // sort by id asc
            comparator = new ListComparator<List<Comparable>>(0);
        }
        Collections.sort(exportJobInfos, comparator);

        return exportJobInfos;
    }

    public void removeOldExportJobs() {
        long currentTimeMs = System.currentTimeMillis();

        writeLock();
        try {
            Iterator<Map.Entry<Long, ExportJob>> iter = idToJob.entrySet().iterator();
            while (iter.hasNext()) {
                Map.Entry<Long, ExportJob> entry = iter.next();
                ExportJob job = entry.getValue();
                if ((currentTimeMs - job.getCreateTimeMs()) / 1000 > Config.export_keep_max_second
                        && (job.getState() == ExportJob.JobState.CANCELLED
                            || job.getState() == ExportJob.JobState.FINISHED)) {
                    iter.remove();
                }
            }

        } finally {
            writeUnlock();
        }

    }

    public void replayCreateExportJob(ExportJob job) {
        writeLock();
        try {
            unprotectAddJob(job);
        } finally {
            writeUnlock();
        }
    }

    public void replayUpdateJobState(long jobId, ExportJob.JobState newState) {
        writeLock();
        try {
            ExportJob job = idToJob.get(jobId);
            job.updateState(newState, true);
        } finally {
            writeUnlock();
        }
    }
}
