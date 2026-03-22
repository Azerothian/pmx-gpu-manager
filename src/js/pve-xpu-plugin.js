/*
 * PVE XPU/GPU Manager Plugin
 * ExtJS 7 frontend for Intel discrete GPU SR-IOV management
 *
 * Registers a "XPU/GPU" tab in PVE.node.Config with:
 *   - Device grid (auto-refresh 30s)
 *   - Device detail panel (properties, telemetry, SR-IOV management)
 *   - VF lifecycle management (create, remove)
 *   - Drift warning banner
 */

/* =========================================================================
 * Utility helpers
 * ========================================================================= */

/**
 * Convert bytes to a human-readable string (B, KB, MB, GB, TB).
 * @param {number} bytes
 * @returns {string}
 */
function xpuFormatBytes(bytes) {
    if (bytes === null || bytes === undefined || isNaN(bytes)) {
        return '-';
    }
    if (bytes === 0) {
        return '0 B';
    }
    var units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var exp = Math.floor(Math.log(bytes) / Math.log(1024));
    exp = Math.min(exp, units.length - 1);
    var value = bytes / Math.pow(1024, exp);
    return value.toFixed(2) + ' ' + units[exp];
}

/**
 * Return a CSS colour token based on GPU temperature.
 * @param {number} temp  Temperature in °C
 * @returns {string}     CSS colour string
 */
function xpuTempColour(temp) {
    if (temp >= 86) {
        return '#e84040'; // red
    }
    if (temp >= 70) {
        return '#f0a020'; // orange
    }
    return '#26a826'; // green
}

/* =========================================================================
 * XpuDeviceStore — backs the main device grid
 * ========================================================================= */

Ext.define('PVE.store.XpuDevices', {
    extend: 'Ext.data.Store',
    alias: 'store.xpuDevices',

    fields: [
        'bdf',
        'device_name',
        'vendor_id',
        'device_id',
        { name: 'subsystem_vendor_id', mapping: 'subsystem_vendor' },
        { name: 'subsystem_device_id', mapping: 'subsystem_device' },
        'family',
        'drm_card',
        { name: 'drm_render', mapping: 'render_node' },
        'driver',
        { name: 'numa_node', type: 'int' },
        { name: 'tiles', type: 'int' },
        { name: 'sriov_capable', type: 'boolean' },
        { name: 'sriov_totalvfs', type: 'int' },
        { name: 'sriov_numvfs', type: 'int' },
        { name: 'persisted', type: 'boolean' },
        'telemetry'
    ],

    proxy: {
        type: 'memory',
        reader: { type: 'json' }
    },

    sorters: [{ property: 'bdf', direction: 'ASC' }]
});

/* =========================================================================
 * XpuDeviceGrid — main device list
 * ========================================================================= */

Ext.define('PVE.grid.XpuDeviceGrid', {
    extend: 'Ext.grid.Panel',
    alias: 'widget.xpuDeviceGrid',

    title: gettext('GPU Devices'),
    collapsible: false,
    stateful: false,

    config: {
        pveSelNode: null
    },

    store: {
        type: 'xpuDevices'
    },

    columns: [
        {
            header: gettext('Device'),
            dataIndex: 'device_name',
            flex: 1,
            minWidth: 200
        },
        {
            header: gettext('BDF'),
            dataIndex: 'bdf',
            width: 140,
            renderer: function(val) {
                return '<span class="x-monospace">' + Ext.htmlEncode(val) + '</span>';
            }
        },
        {
            header: gettext('Device ID'),
            dataIndex: 'device_id',
            width: 100
        },
        {
            header: gettext('Temperature'),
            dataIndex: 'telemetry',
            width: 110,
            renderer: function(telemetry) {
                if (!telemetry || telemetry.temperature_c === null || telemetry.temperature_c === undefined) {
                    return '-';
                }
                var t = telemetry.temperature_c;
                var colour = xpuTempColour(t);
                return '<span style="color:' + colour + ';font-weight:bold;">' + t + ' \u00b0C</span>';
            }
        },
        {
            header: gettext('VRAM'),
            dataIndex: 'telemetry',
            width: 160,
            renderer: function(telemetry) {
                if (!telemetry || telemetry.lmem_total_mb === null || telemetry.lmem_total_mb === undefined) {
                    return '-';
                }
                var total = telemetry.lmem_total_mb;
                var alloc = telemetry.lmem_alloc_mb || 0;
                var totalGiB = (total / 1024).toFixed(1);
                var allocGiB = (alloc / 1024).toFixed(1);
                var pct = total > 0 ? Math.round((alloc / total) * 100) : 0;
                var colour = pct > 80 ? '#e84040' : (pct > 50 ? '#f0a020' : '#26a826');
                return '<span style="color:' + colour + ';">' + allocGiB + ' / ' + totalGiB + ' GiB (' + pct + '%)</span>';
            }
        },
        {
            header: gettext('SR-IOV'),
            dataIndex: 'bdf',
            width: 150,
            renderer: function(val, meta, record) {
                var capable = record.get('sriov_capable') || record.get('sriov_totalvfs') > 0;
                if (!capable) {
                    return '<span style="color:#888;">' + gettext('Not supported') + '</span>';
                }
                var numVfs = record.get('sriov_numvfs');
                if (numVfs > 0) {
                    return '<span style="color:#26a826;">' +
                        Ext.String.format(gettext('Active ({0} VFs)'), numVfs) +
                        '</span>';
                }
                return '<span style="color:#f0a020;">' + gettext('Capable') + '</span>';
            }
        },
        {
            header: gettext('Persisted'),
            dataIndex: 'persisted',
            width: 80,
            align: 'center',
            renderer: function(val) {
                if (val) {
                    return '<i class="fa fa-save" title="' + gettext('Persistent config saved') + '"></i>';
                }
                return '';
            }
        }
    ],

    tbar: [
        {
            xtype: 'button',
            text: gettext('Refresh'),
            iconCls: 'fa fa-refresh',
            handler: function() {
                this.up('xpuDeviceGrid').reload();
            }
        }
    ],

    initComponent: function() {
        var me = this;

        me.callParent();

        me.on('selectionchange', function(selModel, records) {
            if (records.length > 0) {
                me.fireEvent('deviceselect', me, records[0]);
            }
        });

        me.on('itemdblclick', function(grid, record) {
            me.fireEvent('devicedblclick', me, record);
        });

        me.taskRunner = new Ext.util.TaskRunner();

        me.on('afterrender', function() {
            me.reload();
            me.refreshTask = me.taskRunner.start({
                run: function() { me.reload(); },
                interval: 30000
            });
        });

        me.on('destroy', function() {
            if (me.refreshTask) {
                me.taskRunner.stop(me.refreshTask);
            }
        });
    },

    reload: function() {
        var me = this;
        var nodeName = me.pveSelNode && me.pveSelNode.data ? me.pveSelNode.data.node : undefined;
        if (!nodeName) {
            return;
        }

        Proxmox.Utils.API2Request({
            url: '/nodes/' + encodeURIComponent(nodeName) + '/hardware/xpu',
            method: 'GET',
            success: function(response) {
                var data = response.result && response.result.data;
                if (Ext.isArray(data)) {
                    me.getStore().loadData(data);
                }
            },
            failure: function(response, opts, error) {
                Ext.Msg.alert(gettext('Error'), Ext.String.format(
                    gettext('Failed to load GPU devices: {0}'),
                    error || response.htmlStatus
                ));
            }
        });
    }
});

/* =========================================================================
 * XpuPropertiesCard — key-value device properties
 * ========================================================================= */

Ext.define('PVE.panel.XpuPropertiesCard', {
    extend: 'Ext.panel.Panel',
    alias: 'widget.xpuPropertiesCard',

    title: gettext('Properties'),
    bodyPadding: 8,

    tpl: [
        '<table class="xpu-props-table">',
        '<tpl for=".">',
        '<tr>',
        '<td class="xpu-props-key">{label}</td>',
        '<td class="xpu-props-val">{value}</td>',
        '</tr>',
        '</tpl>',
        '</table>'
    ],

    initComponent: function() {
        var me = this;
        me.items = [{
            xtype: 'dataview',
            itemId: 'propsView',
            store: Ext.create('Ext.data.Store', {
                fields: ['label', 'value']
            }),
            tpl: me.tpl,
            itemSelector: 'tr'
        }];
        me.callParent();
    },

    loadRecord: function(record) {
        var me = this;
        if (!record) {
            me.down('#propsView').getStore().removeAll();
            return;
        }
        var data = record.getData();
        var rows = [
            { label: gettext('Family'), value: Ext.htmlEncode(data.family || '-') },
            { label: gettext('Device ID'), value: Ext.htmlEncode(data.device_id || '-') },
            { label: gettext('Vendor ID'), value: Ext.htmlEncode(data.vendor_id || '-') },
            { label: gettext('Driver'), value: Ext.htmlEncode(data.driver || '-') },
            { label: gettext('Firmware'), value: Ext.htmlEncode(data.firmware_version || '-') },
            { label: gettext('DRM Card'), value: Ext.htmlEncode(data.drm_card || '-') },
            { label: gettext('Render Node'), value: Ext.htmlEncode(data.drm_render || '-') },
            { label: gettext('NUMA Node'), value: data.numa_node !== undefined ? String(data.numa_node) : '-' },
            { label: gettext('Tiles'), value: data.tiles !== undefined ? String(data.tiles) : '-' },
            { label: gettext('Max VFs'), value: data.sriov_totalvfs !== undefined ? String(data.sriov_totalvfs) : '-' },
            { label: gettext('Active VFs'), value: data.sriov_numvfs !== undefined ? String(data.sriov_numvfs) : '-' }
        ];
        me.down('#propsView').getStore().loadData(rows);
    }
});

/* =========================================================================
 * XpuTelemetryCard — live telemetry with auto-refresh
 * ========================================================================= */

Ext.define('PVE.panel.XpuTelemetryCard', {
    extend: 'Ext.panel.Panel',
    alias: 'widget.xpuTelemetryCard',

    title: gettext('Telemetry'),
    layout: { type: 'hbox', align: 'stretch', pack: 'start' },
    bodyPadding: 8,

    config: {
        pveSelNode: null,
        currentBdf: null
    },

    initComponent: function() {
        var me = this;

        me.items = [
            // Temperature gauge column
            {
                xtype: 'container',
                itemId: 'tempCol',
                flex: 1,
                padding: '0 8 0 0',
                layout: { type: 'vbox', align: 'stretch' },
                items: [
                    {
                        xtype: 'label',
                        text: gettext('Temperature'),
                        style: 'font-weight:bold;margin-bottom:4px;'
                    },
                    {
                        xtype: 'progressbar',
                        itemId: 'tempBar',
                        height: 24,
                        value: 0,
                        text: '-'
                    },
                    {
                        xtype: 'label',
                        itemId: 'tempRange',
                        text: '0 \u00b0C  \u2015  105 \u00b0C',
                        style: 'font-size:10px;color:#888;margin-top:2px;'
                    }
                ]
            },
            // Power column
            {
                xtype: 'container',
                itemId: 'powerCol',
                flex: 1,
                padding: '0 8',
                layout: { type: 'vbox', align: 'stretch' },
                items: [
                    {
                        xtype: 'label',
                        text: gettext('Power'),
                        style: 'font-weight:bold;margin-bottom:4px;'
                    },
                    {
                        xtype: 'label',
                        itemId: 'powerVal',
                        text: '-',
                        style: 'font-size:22px;font-weight:bold;'
                    },
                    {
                        xtype: 'label',
                        text: 'Watts',
                        style: 'font-size:10px;color:#888;'
                    }
                ]
            },
            // Memory bar column
            {
                xtype: 'container',
                itemId: 'memCol',
                flex: 2,
                padding: '0 0 0 8',
                layout: { type: 'vbox', align: 'stretch' },
                items: [
                    {
                        xtype: 'label',
                        text: gettext('Local Memory (LMEM)'),
                        style: 'font-weight:bold;margin-bottom:4px;'
                    },
                    {
                        xtype: 'progressbar',
                        itemId: 'memBar',
                        height: 24,
                        value: 0,
                        text: '-'
                    },
                    {
                        xtype: 'label',
                        itemId: 'memRange',
                        text: '0  \u2015  0',
                        style: 'font-size:10px;color:#888;margin-top:2px;'
                    }
                ]
            }
        ];

        me.callParent();

        me.taskRunner = new Ext.util.TaskRunner();

        me.on('afterrender', function() {
            me.refreshTask = me.taskRunner.start({
                run: function() { me.reloadTelemetry(); },
                interval: 10000
            });
        });

        me.on('destroy', function() {
            if (me.refreshTask) {
                me.taskRunner.stop(me.refreshTask);
            }
        });
    },

    loadDevice: function(record) {
        var me = this;
        if (!record) {
            me.clearDisplay();
            me.currentBdf = null;
            return;
        }
        me.currentBdf = record.get('bdf');
        // Render telemetry from the device record immediately
        me.updateDisplay(record.get('telemetry'));
        // Then kick off auto-refresh loop
        me.reloadTelemetry();
    },

    reloadTelemetry: function() {
        var me = this;
        var nodeName = me.pveSelNode && me.pveSelNode.data ? me.pveSelNode.data.node : undefined;
        if (!nodeName || !me.currentBdf) {
            return;
        }

        Proxmox.Utils.API2Request({
            url: '/nodes/' + encodeURIComponent(nodeName) +
                 '/hardware/xpu/' + encodeURIComponent(me.currentBdf),
            method: 'GET',
            success: function(response) {
                var data = response.result && response.result.data;
                if (data && data.telemetry) {
                    me.updateDisplay(data.telemetry);
                }
            },
            failure: Ext.emptyFn  // silent fail on telemetry refresh
        });
    },

    updateDisplay: function(telemetry) {
        var me = this;
        if (!telemetry) {
            me.clearDisplay();
            return;
        }

        // Temperature bar (0–105 °C range)
        var tempC = telemetry.temperature_c;
        var tempBar = me.down('#tempBar');
        if (tempBar && tempC !== null && tempC !== undefined) {
            var tempPct = Math.min(tempC / 105, 1);
            var colour = xpuTempColour(tempC);
            tempBar.updateProgress(tempPct, tempC + ' \u00b0C');
            // Colour the bar according to temperature severity
            tempBar.getEl().down('.x-progress-bar').setStyle('background-color', colour);
        }

        // Power label
        var powerVal = me.down('#powerVal');
        if (powerVal) {
            var pw = telemetry.power_w;
            powerVal.setText(pw !== null && pw !== undefined ? pw.toFixed(1) : '-');
        }

        // Memory bar
        var memBar = me.down('#memBar');
        var memRange = me.down('#memRange');
        var total = telemetry.lmem_total_bytes;
        var free = telemetry.lmem_free_bytes;
        if (memBar && total !== null && total !== undefined && total > 0) {
            var used = total - (free || 0);
            var memPct = Math.min(used / total, 1);
            var memText = xpuFormatBytes(used) + ' / ' + xpuFormatBytes(total) +
                          ' (' + Math.round(memPct * 100) + '%)';
            memBar.updateProgress(memPct, memText);
            if (memRange) {
                memRange.setText('0  \u2015  ' + xpuFormatBytes(total));
            }
        }
    },

    clearDisplay: function() {
        var me = this;
        var tempBar = me.down('#tempBar');
        if (tempBar) { tempBar.updateProgress(0, '-'); }
        var powerVal = me.down('#powerVal');
        if (powerVal) { powerVal.setText('-'); }
        var memBar = me.down('#memBar');
        if (memBar) { memBar.updateProgress(0, '-'); }
    }
});

/* =========================================================================
 * XpuPrecheckBar — SR-IOV prerequisite indicator strip
 * ========================================================================= */

Ext.define('PVE.panel.XpuPrecheckBar', {
    extend: 'Ext.panel.Panel',
    alias: 'widget.xpuPrecheckBar',

    title: gettext('SR-IOV Prerequisites'),
    layout: { type: 'hbox', align: 'middle', pack: 'start' },
    bodyPadding: 8,

    initComponent: function() {
        var me = this;

        me.items = me.buildCheckItems([
            { itemId: 'checkCpu', label: gettext('CPU Virtualization') },
            { itemId: 'checkIommu', label: gettext('IOMMU') },
            { itemId: 'checkBios', label: gettext('SR-IOV BIOS') },
            { itemId: 'checkDriver', label: gettext('GPU Driver') }
        ]);

        me.callParent();
    },

    buildCheckItems: function(checks) {
        return checks.map(function(check) {
            return {
                xtype: 'container',
                itemId: check.itemId,
                flex: 1,
                margin: '0 4',
                padding: 6,
                style: 'border:1px solid #ddd;border-radius:4px;background:#f5f5f5;',
                layout: { type: 'vbox', align: 'center' },
                items: [
                    {
                        xtype: 'component',
                        itemId: 'icon',
                        html: '<i class="fa fa-question-circle" style="font-size:20px;color:#aaa;"></i>'
                    },
                    {
                        xtype: 'label',
                        text: check.label,
                        style: 'font-size:11px;margin-top:4px;text-align:center;'
                    },
                    {
                        xtype: 'label',
                        itemId: 'msg',
                        text: '',
                        style: 'font-size:10px;color:#888;text-align:center;margin-top:2px;'
                    }
                ]
            };
        });
    },

    /**
     * Load precheck results from the sriov API response.
     * @param {Array} prechecks  Array of { name, passed, message } objects
     * @returns {boolean}  true if all prechecks passed
     */
    loadPrechecks: function(prechecks) {
        var me = this;
        if (!prechecks || !prechecks.length) {
            return false;
        }

        var idMap = {
            cpu_virtualization: 'checkCpu',
            iommu: 'checkIommu',
            sriov_bios: 'checkBios',
            gpu_driver: 'checkDriver'
        };

        var allPass = true;

        prechecks.forEach(function(check) {
            var containerItemId = idMap[check.name];
            if (!containerItemId) { return; }
            var container = me.down('#' + containerItemId);
            if (!container) { return; }

            var icon = container.down('#icon');
            var msg = container.down('#msg');

            if (check.passed) {
                if (icon) {
                    icon.update('<i class="fa fa-check-circle" style="font-size:20px;color:#26a826;"></i>');
                }
                if (msg) { msg.setText(gettext('Pass')); }
                container.setStyle('background:#efffef;border-color:#b0d8b0;');
            } else {
                allPass = false;
                if (icon) {
                    icon.update('<i class="fa fa-times-circle" style="font-size:20px;color:#e84040;"></i>');
                }
                if (msg) { msg.setText(check.message || gettext('Failed')); }
                container.setStyle('background:#fff2f2;border-color:#d8b0b0;');
            }
        });

        return allPass;
    }
});

/* =========================================================================
 * XpuDriftBanner — shown when persisted config != runtime state
 * ========================================================================= */

Ext.define('PVE.panel.XpuDriftBanner', {
    extend: 'Ext.panel.Panel',
    alias: 'widget.xpuDriftBanner',

    hidden: true,
    bodyStyle: 'background:#fffbe6;border:1px solid #f0a020;padding:8px 12px;',
    layout: 'hbox',

    config: {
        pveSelNode: null,
        currentBdf: null
    },

    initComponent: function() {
        var me = this;

        me.items = [
            {
                xtype: 'component',
                html: '<i class="fa fa-exclamation-triangle" style="font-size:20px;color:#f0a020;margin-right:8px;"></i>',
                margin: '0 8 0 0'
            },
            {
                xtype: 'container',
                flex: 1,
                layout: 'vbox',
                items: [
                    {
                        xtype: 'label',
                        itemId: 'driftTitle',
                        text: gettext('Configuration Drift Detected'),
                        style: 'font-weight:bold;color:#7a5000;'
                    },
                    {
                        xtype: 'label',
                        itemId: 'driftMsg',
                        text: '',
                        style: 'color:#7a5000;'
                    }
                ]
            },
            {
                xtype: 'button',
                text: gettext('Re-apply Config'),
                iconCls: 'fa fa-redo',
                margin: '0 4',
                handler: function() { me.reapplyConfig(); }
            },
            {
                xtype: 'button',
                text: gettext('Dismiss'),
                handler: function() { me.hide(); }
            }
        ];

        me.callParent();
    },

    showDrift: function(drift) {
        var me = this;
        if (!drift || !drift.detected) {
            me.hide();
            return;
        }
        var msgCmp = me.down('#driftMsg');
        if (msgCmp) {
            msgCmp.setText(drift.message || gettext('Persisted SR-IOV configuration does not match running state.'));
        }
        me.show();
    },

    reapplyConfig: function() {
        var me = this;
        var nodeName = me.pveSelNode && me.pveSelNode.data ? me.pveSelNode.data.node : undefined;
        if (!nodeName || !me.currentBdf) { return; }

        me.setLoading(true);
        Proxmox.Utils.API2Request({
            url: '/nodes/' + encodeURIComponent(nodeName) +
                 '/hardware/xpu/' + encodeURIComponent(me.currentBdf) + '/sriov/apply',
            method: 'POST',
            success: function() {
                me.setLoading(false);
                me.hide();
                me.fireEvent('configapplied', me);
            },
            failure: function(response, opts, error) {
                me.setLoading(false);
                Ext.Msg.alert(gettext('Error'), Ext.String.format(
                    gettext('Failed to re-apply config: {0}'),
                    error || response.htmlStatus
                ));
            }
        });
    }
});

/* =========================================================================
 * XpuVfStore — backs the VF grid
 * ========================================================================= */

Ext.define('PVE.store.XpuVfs', {
    extend: 'Ext.data.Store',
    alias: 'store.xpuVfs',

    fields: [
        { name: 'vf_index', type: 'auto' },
        'bdf',
        { name: 'lmem_quota', type: 'auto' },
        { name: 'ggtt_quota', type: 'auto' },
        { name: 'exec_quantum_ms', type: 'auto' },
        { name: 'preempt_timeout_us', type: 'auto' },
        { name: 'assigned', type: 'auto' },
        { name: 'vmid', type: 'auto' }
    ],

    proxy: {
        type: 'memory',
        reader: { type: 'json' }
    },

    sorters: [{ property: 'vf_index', direction: 'ASC' }]
});

/* =========================================================================
 * CreateVfsDialog — modal window for VF creation
 * ========================================================================= */

Ext.define('PVE.window.CreateVfsDialog', {
    extend: 'Ext.window.Window',
    alias: 'widget.xpuCreateVfsDialog',

    title: gettext('Create Virtual Functions'),
    modal: true,
    width: 520,
    layout: 'fit',
    resizable: false,

    config: {
        pveSelNode: null,
        deviceRecord: null
    },

    initComponent: function() {
        var me = this;
        var rec = me.deviceRecord;
        var deviceName = rec ? rec.get('device_name') : '-';
        var bdf = rec ? rec.get('bdf') : '-';
        var totalVfs = rec ? (rec.get('sriov_totalvfs') || 1) : 1;
        var deviceId = rec ? rec.get('device_id') : null;

        me.items = [
            {
                xtype: 'form',
                itemId: 'createForm',
                bodyPadding: 12,
                defaults: { anchor: '100%', labelWidth: 160 },
                items: [
                    {
                        xtype: 'displayfield',
                        fieldLabel: gettext('Device'),
                        value: Ext.htmlEncode(deviceName + ' (' + bdf + ')')
                    },
                    {
                        xtype: 'displayfield',
                        fieldLabel: gettext('Available'),
                        itemId: 'availInfo',
                        value: Ext.String.format(gettext('{0} VFs max'), totalVfs)
                    },
                    { xtype: 'numberfield', itemId: 'numVfsField', fieldLabel: gettext('Number of VFs'),
                      name: 'num_vfs', value: 1, minValue: 1, maxValue: totalVfs,
                      allowBlank: false },
                    { xtype: 'combobox', itemId: 'templateField', fieldLabel: gettext('Template'),
                      name: 'template', queryMode: 'local', displayField: 'name', valueField: 'name',
                      emptyText: gettext('None (manual)'), forceSelection: false, editable: false,
                      store: Ext.create('Ext.data.Store', {
                          fields: ['name', 'num_vfs', 'vf_lmem', 'vf_ggtt', 'vf_contexts',
                                   'vf_doorbells', 'scheduler', 'drivers_autoprobe'],
                          data: []
                      })
                    },
                    {
                        xtype: 'fieldset',
                        title: gettext('Resource Allocation (per VF)'),
                        itemId: 'manualFields',
                        defaults: { labelWidth: 160, anchor: '100%' },
                        items: [
                            { xtype: 'numberfield', itemId: 'lmemField', fieldLabel: gettext('LMEM per VF (bytes)'),
                              name: 'lmem_per_vf', minValue: 0, step: 1048576,
                              emptyText: gettext('auto-split') },
                            { xtype: 'displayfield', itemId: 'lmemHint', value: '', style: 'color:#888;' },
                            { xtype: 'numberfield', itemId: 'ggttField', fieldLabel: gettext('GGTT per VF (bytes)'),
                              name: 'ggtt_per_vf', minValue: 0, step: 1048576,
                              emptyText: gettext('auto-split') },
                            { xtype: 'numberfield', itemId: 'contextsField', fieldLabel: gettext('Contexts per VF'),
                              name: 'contexts_per_vf', minValue: 1, value: 1024 },
                            { xtype: 'numberfield', itemId: 'doorbellsField', fieldLabel: gettext('Doorbells per VF'),
                              name: 'doorbells_per_vf', minValue: 1, value: 60 },
                            { xtype: 'numberfield', itemId: 'execQuantumField', fieldLabel: gettext('Exec Quantum (ms)'),
                              name: 'exec_quantum_ms', minValue: 1, value: 20 },
                            { xtype: 'numberfield', itemId: 'preemptField', fieldLabel: gettext('Preempt Timeout (\u03bcs)'),
                              name: 'preempt_timeout_us', minValue: 1, value: 1000 }
                        ]
                    },
                    {
                        xtype: 'fieldset',
                        title: gettext('Options'),
                        defaults: { anchor: '100%' },
                        items: [
                            { xtype: 'checkbox', fieldLabel: gettext('Persist across reboots'),
                              name: 'persist', checked: true, inputValue: 1, uncheckedValue: 0 },
                            { xtype: 'checkbox', fieldLabel: gettext('Auto-probe drivers'),
                              name: 'drivers_autoprobe', checked: false, inputValue: 1, uncheckedValue: 0 }
                        ]
                    }
                ]
            }
        ];

        me.buttons = [
            {
                text: gettext('Cancel'),
                handler: function() { me.close(); }
            },
            {
                xtype: 'button',
                text: gettext('Create VFs'),
                itemId: 'createBtn',
                iconCls: 'fa fa-plus',
                formBind: true,
                handler: function() { me.doCreate(); }
            }
        ];

        me.callParent();

        // Load templates for this device
        me.loadTemplates(deviceId);

        // Wire template selection -> auto-populate
        var templateField = me.down('#templateField');
        if (templateField) {
            templateField.on('select', function(combo, templateRecord) {
                me.applyTemplate(templateRecord);
            });
            templateField.on('change', function(combo, val) {
                if (!val) {
                    me.clearTemplate();
                }
            });
        }

        // Wire LMEM field to show human-readable hint
        var lmemField = me.down('#lmemField');
        if (lmemField) {
            lmemField.on('change', function(field, val) {
                var hint = me.down('#lmemHint');
                if (hint) {
                    hint.setValue(val ? '= ' + xpuFormatBytes(val) : '');
                }
            });
        }
    },

    loadTemplates: function(deviceId) {
        var me = this;
        var nodeName = me.pveSelNode && me.pveSelNode.data ? me.pveSelNode.data.node : undefined;
        if (!nodeName) { return; }

        Proxmox.Utils.API2Request({
            url: '/nodes/' + encodeURIComponent(nodeName) + '/hardware/xpu/templates',
            params: deviceId ? { device_id: deviceId } : {},
            method: 'GET',
            success: function(response) {
                var data = response.result && response.result.data;
                if (Ext.isArray(data)) {
                    var templateField = me.down('#templateField');
                    if (templateField) {
                        templateField.getStore().loadData(data);
                    }
                }
            },
            failure: Ext.emptyFn  // templates are optional
        });
    },

    applyTemplate: function(templateRecord) {
        var me = this;
        if (!templateRecord) { return; }

        var numVfsField = me.down('#numVfsField');
        var lmemField = me.down('#lmemField');
        var ggttField = me.down('#ggttField');
        var contextsField = me.down('#contextsField');
        var doorbellsField = me.down('#doorbellsField');

        if (numVfsField && templateRecord.get('num_vfs')) {
            numVfsField.setValue(templateRecord.get('num_vfs'));
        }
        if (lmemField && templateRecord.get('vf_lmem')) {
            lmemField.setValue(templateRecord.get('vf_lmem'));
            lmemField.setReadOnly(true);
        }
        if (ggttField && templateRecord.get('vf_ggtt')) {
            ggttField.setValue(templateRecord.get('vf_ggtt'));
            ggttField.setReadOnly(true);
        }
        if (contextsField && templateRecord.get('vf_contexts')) {
            contextsField.setValue(templateRecord.get('vf_contexts'));
            contextsField.setReadOnly(true);
        }
        if (doorbellsField && templateRecord.get('vf_doorbells')) {
            doorbellsField.setValue(templateRecord.get('vf_doorbells'));
            doorbellsField.setReadOnly(true);
        }
    },

    clearTemplate: function() {
        var me = this;
        ['#lmemField', '#ggttField', '#contextsField', '#doorbellsField'].forEach(function(sel) {
            var f = me.down(sel);
            if (f) { f.setReadOnly(false); }
        });
    },

    doCreate: function() {
        var me = this;
        var form = me.down('#createForm');
        if (!form.isValid()) { return; }

        var nodeName = me.pveSelNode && me.pveSelNode.data ? me.pveSelNode.data.node : undefined;
        var bdf = me.deviceRecord ? me.deviceRecord.get('bdf') : null;
        if (!nodeName || !bdf) { return; }

        var values = form.getValues();
        me.setLoading(true);

        Proxmox.Utils.API2Request({
            url: '/nodes/' + encodeURIComponent(nodeName) +
                 '/hardware/xpu/' + encodeURIComponent(bdf) + '/sriov',
            method: 'POST',
            params: values,
            success: function() {
                me.setLoading(false);
                me.close();
                me.fireEvent('vfscreated', me);
            },
            failure: function(response, opts, error) {
                me.setLoading(false);
                Ext.Msg.alert(gettext('Error'), Ext.String.format(
                    gettext('Failed to create VFs: {0}'),
                    error || response.htmlStatus
                ));
            }
        });
    }
});

/* =========================================================================
 * XpuSriovPanel — VF management section (precheck + VF grid)
 * ========================================================================= */

Ext.define('PVE.panel.XpuSriovPanel', {
    extend: 'Ext.panel.Panel',
    alias: 'widget.xpuSriovPanel',

    title: gettext('SR-IOV Virtual Functions'),
    layout: { type: 'vbox', align: 'stretch' },

    config: {
        pveSelNode: null,
        deviceRecord: null
    },

    initComponent: function() {
        var me = this;

        me.items = [
            // Drift banner
            {
                xtype: 'xpuDriftBanner',
                itemId: 'driftBanner',
                pveSelNode: me.pveSelNode
            },
            // VF grid
            {
                xtype: 'gridpanel',
                itemId: 'vfGrid',
                flex: 1,
                store: { type: 'xpuVfs' },
                columns: [
                    { header: gettext('VF #'), dataIndex: 'vf_index', width: 60, align: 'center' },
                    {
                        header: gettext('BDF'), dataIndex: 'bdf', flex: 1, minWidth: 140,
                        renderer: function(val) {
                            return '<span class="x-monospace">' + Ext.htmlEncode(val || '-') + '</span>';
                        }
                    },
                    {
                        header: gettext('LMEM'), dataIndex: 'lmem_quota', width: 120,
                        renderer: function(val) {
                            var n = Number(val);
                            return (n > 0) ? xpuFormatBytes(n) : '-';
                        }
                    },
                    {
                        header: gettext('GGTT'), dataIndex: 'ggtt_quota', width: 120,
                        renderer: function(val) {
                            var n = Number(val);
                            return (n > 0) ? xpuFormatBytes(n) : '-';
                        }
                    },
                    {
                        header: gettext('Status'), dataIndex: 'assigned', width: 100,
                        renderer: function(val, meta, record) {
                            if (val) {
                                return '<span style="color:#26a826;">' + gettext('Assigned') + '</span>';
                            }
                            return '<span style="color:#888;">' + gettext('Available') + '</span>';
                        }
                    },
                    {
                        header: gettext('VM'), dataIndex: 'vmid', width: 80,
                        renderer: function(val) { return val ? String(val) : '\u2014'; }
                    }
                ],
                tbar: [
                    {
                        xtype: 'button',
                        itemId: 'createVfsBtn',
                        text: gettext('Create VFs'),
                        iconCls: 'fa fa-plus',
                        disabled: true,
                        handler: function() { me.openCreateDialog(); }
                    },
                    {
                        xtype: 'button',
                        itemId: 'removeVfsBtn',
                        text: gettext('Remove All VFs'),
                        iconCls: 'fa fa-trash',
                        disabled: true,
                        handler: function() { me.confirmRemoveVfs(); }
                    }
                ]
            }
        ];

        me.callParent();
    },

    /**
     * Load SR-IOV status for a device.
     * @param {Ext.data.Model} deviceRecord
     */
    loadDevice: function(deviceRecord) {
        var me = this;
        me.deviceRecord = deviceRecord;

        var capable = deviceRecord && (deviceRecord.get('sriov_capable') || deviceRecord.get('sriov_totalvfs') > 0);
        if (!capable) {
            me.disable();
            me.setTitle(gettext('SR-IOV Virtual Functions') + ' \u2014 ' + gettext('Not supported'));
            me.down('#createVfsBtn').setDisabled(true);
            me.down('#removeVfsBtn').setDisabled(true);
            me.down('#vfGrid').getStore().removeAll();
            return;
        }

        me.enable();
        me.setTitle(gettext('SR-IOV Virtual Functions'));
        me.reloadSriov();
        me.reloadVfs();
    },

    reloadSriov: function() {
        var me = this;
        var nodeName = me.pveSelNode && me.pveSelNode.data ? me.pveSelNode.data.node : undefined;
        var bdf = me.deviceRecord ? me.deviceRecord.get('bdf') : null;
        if (!nodeName || !bdf) { return; }

        Proxmox.Utils.API2Request({
            url: '/nodes/' + encodeURIComponent(nodeName) +
                 '/hardware/xpu/' + encodeURIComponent(bdf) + '/sriov',
            method: 'GET',
            success: function(response) {
                var data = response.result && response.result.data;
                if (!data) { return; }

                // Drift banner
                var driftBanner = me.down('#driftBanner');
                if (driftBanner) {
                    driftBanner.pveSelNode = me.pveSelNode;
                    driftBanner.currentBdf = bdf;
                    driftBanner.showDrift(data.drift);
                }

                // Enable/disable Create button based on SR-IOV capability
                var createBtn = me.down('#createVfsBtn');
                if (createBtn) {
                    var numVfsCurrent = me.deviceRecord ? me.deviceRecord.get('sriov_numvfs') : 0;
                    // Disable Create if VFs are already active (must remove first)
                    createBtn.setDisabled(numVfsCurrent > 0);
                }

                var removeBtn = me.down('#removeVfsBtn');
                var numVfs = me.deviceRecord ? me.deviceRecord.get('sriov_numvfs') : 0;
                if (removeBtn) {
                    removeBtn.setDisabled(!numVfs || numVfs === 0);
                }
            },
            failure: function(response, opts, error) {
                Ext.Msg.alert(gettext('Error'), Ext.String.format(
                    gettext('Failed to load SR-IOV status: {0}'),
                    error || response.htmlStatus
                ));
            }
        });
    },

    reloadVfs: function() {
        var me = this;
        var nodeName = me.pveSelNode && me.pveSelNode.data ? me.pveSelNode.data.node : undefined;
        var bdf = me.deviceRecord ? me.deviceRecord.get('bdf') : null;
        if (!nodeName || !bdf) { return; }

        Proxmox.Utils.API2Request({
            url: '/nodes/' + encodeURIComponent(nodeName) +
                 '/hardware/xpu/' + encodeURIComponent(bdf) + '/vf',
            method: 'GET',
            success: function(response) {
                var data = response.result && response.result.data;
                var store = me.down('#vfGrid').getStore();
                if (Ext.isArray(data)) {
                    store.loadData(data);
                } else {
                    store.removeAll();
                }
            },
            failure: Ext.emptyFn
        });
    },

    openCreateDialog: function() {
        var me = this;
        var dlg = Ext.create('PVE.window.CreateVfsDialog', {
            pveSelNode: me.pveSelNode,
            deviceRecord: me.deviceRecord
        });
        dlg.on('vfscreated', function() {
            me.reloadVfs();
            me.fireEvent('vfschanged', me);
        });
        dlg.show();
    },

    confirmRemoveVfs: function() {
        var me = this;
        var numVfs = me.deviceRecord ? me.deviceRecord.get('sriov_numvfs') : 0;
        var deviceName = me.deviceRecord ? me.deviceRecord.get('device_name') : '-';

        Ext.create('Ext.window.Window', {
            title: gettext('Remove Virtual Functions'),
            modal: true,
            width: 420,
            layout: 'fit',
            items: [
                {
                    xtype: 'form',
                    bodyPadding: 12,
                    items: [
                        {
                            xtype: 'component',
                            html: '<i class="fa fa-exclamation-triangle" style="color:#f0a020;"></i> ' +
                                  Ext.String.format(
                                      gettext('Are you sure you want to remove all {0} virtual function(s) from {1}?'),
                                      numVfs, Ext.htmlEncode(deviceName)
                                  )
                        },
                        {
                            xtype: 'checkbox',
                            itemId: 'removePersistCb',
                            fieldLabel: gettext('Also remove persistent boot configuration'),
                            checked: true,
                            inputValue: 1,
                            uncheckedValue: 0,
                            margin: '12 0 0 0'
                        }
                    ]
                }
            ],
            buttons: [
                {
                    text: gettext('Cancel'),
                    handler: function() { this.up('window').close(); }
                },
                {
                    text: gettext('Remove VFs'),
                    iconCls: 'fa fa-trash',
                    handler: function() {
                        var win = this.up('window');
                        var removePersist = win.down('#removePersistCb').getValue();
                        win.close();
                        me.doRemoveVfs(removePersist);
                    }
                }
            ]
        }).show();
    },

    doRemoveVfs: function(removePersist) {
        var me = this;
        var nodeName = me.pveSelNode && me.pveSelNode.data ? me.pveSelNode.data.node : undefined;
        var bdf = me.deviceRecord ? me.deviceRecord.get('bdf') : null;
        if (!nodeName || !bdf) { return; }

        me.setLoading(true);
        Proxmox.Utils.API2Request({
            url: '/nodes/' + encodeURIComponent(nodeName) +
                 '/hardware/xpu/' + encodeURIComponent(bdf) + '/sriov',
            method: 'DELETE',
            params: { remove_persist: removePersist ? 1 : 0 },
            success: function() {
                me.setLoading(false);
                me.reloadVfs();
                me.fireEvent('vfschanged', me);
            },
            failure: function(response, opts, error) {
                me.setLoading(false);
                Ext.Msg.alert(gettext('Error'), Ext.String.format(
                    gettext('Failed to remove VFs: {0}'),
                    error || response.htmlStatus
                ));
            }
        });
    }
});

/* =========================================================================
 * XpuDeviceDetail — right/bottom panel shown on row selection
 * ========================================================================= */

Ext.define('PVE.panel.XpuDeviceDetail', {
    extend: 'Ext.panel.Panel',
    alias: 'widget.xpuDeviceDetail',

    title: gettext('Device Detail'),
    layout: { type: 'vbox', align: 'stretch' },
    bodyPadding: 0,
    scrollable: 'y',

    config: {
        pveSelNode: null
    },

    initComponent: function() {
        var me = this;

        me.items = [
            // Top row: properties + telemetry side by side
            {
                xtype: 'container',
                layout: { type: 'hbox', align: 'stretch' },
                height: 230,
                items: [
                    {
                        xtype: 'xpuPropertiesCard',
                        itemId: 'propsCard',
                        flex: 1,
                        margin: '0 4 4 0',
                        border: true
                    },
                    {
                        xtype: 'xpuTelemetryCard',
                        itemId: 'telemetryCard',
                        flex: 2,
                        margin: '0 0 4 4',
                        border: true,
                        pveSelNode: me.pveSelNode
                    }
                ]
            },
            // SR-IOV panel
            {
                xtype: 'xpuSriovPanel',
                itemId: 'sriovPanel',
                flex: 1,
                minHeight: 280,
                pveSelNode: me.pveSelNode
            }
        ];

        me.callParent();

        // Propagate vfschanged up so the device grid can refresh
        me.down('#sriovPanel').on('vfschanged', function() {
            me.fireEvent('vfschanged', me);
        });
    },

    loadDevice: function(record) {
        var me = this;
        if (!record) {
            me.setTitle(gettext('Device Detail'));
            return;
        }

        me.setTitle(Ext.String.format(
            gettext('Device Detail: {0} ({1})'),
            record.get('device_name'),
            record.get('bdf')
        ));

        me.down('#propsCard').loadRecord(record);
        me.down('#telemetryCard').loadDevice(record);
        me.down('#sriovPanel').loadDevice(record);
    }
});

/* =========================================================================
 * XpuManager — the main node tab panel
 * ========================================================================= */

Ext.define('PVE.node.XpuManager', {
    extend: 'Ext.panel.Panel',
    alias: 'widget.pveXpuManager',

    layout: { type: 'border' },

    config: {
        pveSelNode: null
    },

    initComponent: function() {
        var me = this;

        me.items = [
            // Device grid — north region
            {
                xtype: 'xpuDeviceGrid',
                itemId: 'deviceGrid',
                region: 'north',
                height: 240,
                split: true,
                pveSelNode: me.pveSelNode,
                listeners: {
                    deviceselect: function(grid, record) {
                        me.down('#deviceDetail').loadDevice(record);
                    }
                }
            },
            // Device detail — center region
            {
                xtype: 'xpuDeviceDetail',
                itemId: 'deviceDetail',
                region: 'center',
                pveSelNode: me.pveSelNode,
                listeners: {
                    vfschanged: function() {
                        // Refresh device grid so VF counts / persisted icons update
                        me.down('#deviceGrid').reload();
                    }
                }
            }
        ];

        me.callParent();
    }
});

/* =========================================================================
 * Tab registration — inject XPU/GPU tab into PVE.node.Config
 *
 * PVE.node.Config uses an items array; we override initComponent on the
 * existing class to push our tab in. This follows the same pattern used by
 * other PVE UI plugins (e.g. PVE-mods).
 * ========================================================================= */

// Override PVE.node.Config to inject our XPU/GPU tab.
// PVE.panel.Config.initComponent processes me.items via insertNodes(),
// which adds them to both savedItems and the tree store for navigation.
// After callParent(), insertNodes() is still available to add more items.
Ext.define('PVE.node.XpuManagerOverride', {
    override: 'PVE.node.Config',

    initComponent: function() {
        var me = this;

        // Call the original initComponent chain
        me.callParent(arguments);

        // Use PVE.panel.Config's insertNodes to properly register our tab
        // in both the tree navigation and the card layout
        me.insertNodes([{
            xtype: 'pveXpuManager',
            title: gettext('XPU/GPU'),
            iconCls: 'fa fa-microchip',
            itemId: 'xpugpu',
            pveSelNode: me.pveSelNode,
            nodename: me.pveSelNode.data.node
        }]);
    }
});

/* =========================================================================
 * CSS injection — inline styles for monospace BDF and properties table
 * ========================================================================= */

(function() {
    var styleId = 'pve-xpu-plugin-styles';
    if (document.getElementById(styleId)) { return; }

    var style = document.createElement('style');
    style.id = styleId;
    style.type = 'text/css';
    // PVE Proxmox Dark theme loads a separate CSS file that sets
    // --pwt-panel-background and --pwt-text-color on :root, plus
    // color-scheme:dark. It does NOT add a body class.
    //
    // Strategy: use color-scheme media query for dark detection,
    // since PVE dark theme sets color-scheme:dark on :root which
    // propagates to prefers-color-scheme media queries.
    style.textContent = [
        '.x-monospace { font-family: monospace; }',

        // Light mode (default)
        '.xpu-props-table {',
        '  width: 100%;',
        '  border-collapse: collapse;',
        '  border: 1px solid #e0e0e0;',
        '}',
        '.xpu-props-table tr:nth-child(even) { background: #f0f0f0; }',
        '.xpu-props-table tr:nth-child(odd) { background: #fafafa; }',
        '.xpu-props-table tr:hover { background: #e0ecf5; }',
        '.xpu-props-key {',
        '  padding: 5px 10px;',
        '  font-weight: 600;',
        '  color: #444;',
        '  width: 150px;',
        '  white-space: nowrap;',
        '  border-right: 1px solid #e0e0e0;',
        '  opacity: 0.8;',
        '}',
        '.xpu-props-val {',
        '  padding: 5px 10px;',
        '  font-family: monospace;',
        '  color: #222;',
        '}'
    ].join('\n');

    // Dark mode: dynamically update styles when dark theme is detected.
    // PVE dark theme loads a CSS file that sets --pwt-panel-background on :root.
    // We detect this and inject dark overrides with !important to ensure they win.
    var darkStyleId = 'pve-xpu-plugin-dark';
    var darkCSS = [
        '.xpu-props-table { border-color: #404040 !important; }',
        '.xpu-props-table tr:nth-child(even) { background: #1a1a1a !important; }',
        '.xpu-props-table tr:nth-child(odd) { background: #262626 !important; }',
        '.xpu-props-table tr:hover { background: #595959 !important; }',
        '.xpu-props-key { color: #b0b0b0 !important; border-right-color: #404040 !important; }',
        '.xpu-props-val { color: #f2f2f2 !important; }'
    ].join('\n');

    var applyTheme = function() {
        var pwtBg = getComputedStyle(document.documentElement)
            .getPropertyValue('--pwt-panel-background').trim();
        var isDark = pwtBg !== '';
        var darkEl = document.getElementById(darkStyleId);

        if (isDark && !darkEl) {
            var ds = document.createElement('style');
            ds.id = darkStyleId;
            ds.textContent = darkCSS;
            document.head.appendChild(ds);
        } else if (!isDark && darkEl) {
            darkEl.remove();
        }
    };

    // Check theme on load, after short delays (CSS may not be parsed yet),
    // and on any stylesheet changes
    applyTheme();
    setTimeout(applyTheme, 500);
    setTimeout(applyTheme, 2000);
    new MutationObserver(function() {
        applyTheme();
        setTimeout(applyTheme, 200);
    }).observe(document.head, { childList: true });
    document.head.appendChild(style);
}());
