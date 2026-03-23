/*
 * GPU Manager for Proxmox VE
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
        { name: 'sriov_maxvfs', type: 'int' },
        { name: 'sriov_numvfs', type: 'int' },
        { name: 'persisted', type: 'boolean' },
        'telemetry',
        'firmware_version',
        { name: 'assigned_vms', type: 'auto' },
        { name: 'pf_assigned', type: 'boolean' },
        { name: 'pf_vmid', type: 'auto' }
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
            minWidth: 180
        },
        {
            header: gettext('BDF'),
            dataIndex: 'bdf',
            width: 130,
            renderer: function(val) {
                return '<span class="x-monospace">' + Ext.htmlEncode(val) + '</span>';
            }
        },
        {
            header: gettext('GPU Core'),
            dataIndex: 'telemetry',
            width: 80,
            align: 'center',
            renderer: function(telemetry) {
                if (!telemetry || telemetry.temperature_c === null || telemetry.temperature_c === undefined) {
                    return '-';
                }
                var t = telemetry.temperature_c;
                var colour = xpuTempColour(t);
                return '<span style="color:' + colour + ';font-weight:bold;">' + t + '\u00b0C</span>';
            }
        },
        {
            header: gettext('GPU Mem'),
            dataIndex: 'telemetry',
            width: 80,
            align: 'center',
            renderer: function(telemetry) {
                if (!telemetry || telemetry.mem_temperature_c === null || telemetry.mem_temperature_c === undefined) {
                    return '-';
                }
                var t = telemetry.mem_temperature_c;
                var colour = xpuTempColour(t);
                return '<span style="color:' + colour + ';font-weight:bold;">' + t + '\u00b0C</span>';
            }
        },
        {
            header: gettext('Power'),
            dataIndex: 'telemetry',
            width: 70,
            align: 'center',
            renderer: function(telemetry) {
                if (!telemetry) { return '-'; }
                if (telemetry.power_w !== null && telemetry.power_w !== undefined) {
                    return telemetry.power_w + 'W';
                }
                if (telemetry.power_tdp_w) {
                    return '<span style="color:#888;">' + telemetry.power_tdp_w + 'W</span>';
                }
                return '-';
            }
        },
        {
            header: gettext('Freq'),
            dataIndex: 'telemetry',
            width: 90,
            align: 'center',
            renderer: function(telemetry) {
                if (!telemetry || !telemetry.clock_mhz) { return '-'; }
                var text = telemetry.clock_mhz + ' MHz';
                if (telemetry.clock_max_mhz && telemetry.clock_max_mhz !== telemetry.clock_mhz) {
                    text += ' / ' + telemetry.clock_max_mhz;
                }
                return text;
            }
        },
        {
            header: gettext('VRAM'),
            dataIndex: 'telemetry',
            width: 140,
            renderer: function(telemetry) {
                if (!telemetry || telemetry.lmem_total_mb === null || telemetry.lmem_total_mb === undefined) {
                    return '-';
                }
                var total = telemetry.lmem_total_mb;
                var used = telemetry.lmem_used_mb || 0;
                var totalGiB = (total / 1024).toFixed(1);
                var usedGiB = (used / 1024).toFixed(1);
                var pct = total > 0 ? Math.round((used / total) * 100) : 0;
                var colour = pct > 80 ? '#e84040' : (pct > 50 ? '#f0a020' : '#26a826');
                return '<span style="color:' + colour + ';">' + usedGiB + '/' + totalGiB + ' GiB</span>';
            }
        },
        {
            header: gettext('GPU %'),
            dataIndex: 'telemetry',
            width: 65,
            align: 'center',
            renderer: function(telemetry) {
                if (!telemetry || telemetry.gpu_util_pct === null || telemetry.gpu_util_pct === undefined) { return '-'; }
                var pct = parseFloat(telemetry.gpu_util_pct);
                var colour = pct > 80 ? '#e84040' : (pct > 50 ? '#f0a020' : '#26a826');
                return '<span style="color:' + colour + ';font-weight:bold;">' + pct + '%</span>';
            }
        },
        {
            header: gettext('Fan'),
            dataIndex: 'telemetry',
            width: 70,
            align: 'center',
            renderer: function(telemetry) {
                if (!telemetry || telemetry.fan_rpm === null || telemetry.fan_rpm === undefined) { return '-'; }
                return telemetry.fan_rpm + ' rpm';
            }
        },
        {
            header: gettext('Health'),
            dataIndex: 'telemetry',
            width: 70,
            align: 'center',
            renderer: function(telemetry) {
                if (!telemetry || !telemetry.health) { return '-'; }
                if (telemetry.health === 'OK') {
                    return '<span style="color:#26a826;"><i class="fa fa-check-circle"></i> OK</span>';
                }
                return '<span style="color:#e84040;"><i class="fa fa-exclamation-triangle"></i></span>';
            }
        },
        {
            header: gettext('Max VFs'),
            dataIndex: 'sriov_maxvfs',
            width: 60,
            align: 'center'
        },
        {
            header: gettext('VMs'),
            dataIndex: 'assigned_vms',
            width: 100,
            renderer: function(vms) {
                if (!vms || !vms.length) { return '\u2014'; }
                return vms.join(', ');
            }
        },
        {
            header: gettext('SR-IOV'),
            dataIndex: 'bdf',
            width: 120,
            renderer: function(val, meta, record) {
                var capable = record.get('sriov_capable') || record.get('sriov_maxvfs') > 0;
                if (!capable) {
                    return '<span style="color:#888;">' + gettext('N/A') + '</span>';
                }
                var numVfs = record.get('sriov_numvfs');
                if (numVfs > 0) {
                    return '<span style="color:#26a826;">' +
                        Ext.String.format(gettext('{0} VFs'), numVfs) +
                        '</span>';
                }
                return '<span style="color:#f0a020;">' + gettext('Ready') + '</span>';
            }
        },
        {
            header: gettext('Persisted'),
            dataIndex: 'persisted',
            width: 70,
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
    scrollable: 'y',

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
            { label: gettext('SR-IOV Max VFs'), value: data.sriov_maxvfs !== undefined ? String(data.sriov_maxvfs) : '-' },
            { label: gettext('SR-IOV Active VFs'), value: data.sriov_numvfs !== undefined ? String(data.sriov_numvfs) : '-' }
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
            // Clock rate column
            {
                xtype: 'container',
                itemId: 'clockCol',
                flex: 1,
                padding: '0 8',
                layout: { type: 'vbox', align: 'stretch' },
                items: [
                    {
                        xtype: 'label',
                        text: gettext('Clock'),
                        style: 'font-weight:bold;margin-bottom:4px;'
                    },
                    {
                        xtype: 'label',
                        itemId: 'clockVal',
                        text: '-',
                        style: 'font-size:22px;font-weight:bold;'
                    },
                    {
                        xtype: 'label',
                        itemId: 'clockMax',
                        text: '',
                        style: 'font-size:10px;color:#888;'
                    }
                ]
            },
            // Fan speed column
            {
                xtype: 'container',
                itemId: 'fanCol',
                flex: 1,
                padding: '0 8',
                layout: { type: 'vbox', align: 'stretch' },
                items: [
                    {
                        xtype: 'label',
                        text: gettext('Fan'),
                        style: 'font-weight:bold;margin-bottom:4px;'
                    },
                    {
                        xtype: 'label',
                        itemId: 'fanVal',
                        text: '-',
                        style: 'font-size:22px;font-weight:bold;'
                    },
                    {
                        xtype: 'label',
                        text: 'RPM',
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
            if (pw !== null && pw !== undefined) {
                powerVal.setText(String(pw));
            } else if (telemetry.power_tdp_w) {
                powerVal.setText(telemetry.power_tdp_w + ' (TDP)');
            } else {
                powerVal.setText('-');
            }
        }

        // Clock rate
        var clockVal = me.down('#clockVal');
        var clockMax = me.down('#clockMax');
        if (clockVal) {
            var mhz = telemetry.clock_mhz;
            clockVal.setText(mhz !== null && mhz !== undefined ? mhz + ' MHz' : '-');
        }
        if (clockMax) {
            var maxMhz = telemetry.clock_max_mhz;
            clockMax.setText(maxMhz ? 'Max: ' + maxMhz + ' MHz' : '');
        }

        // Fan speed
        var fanVal = me.down('#fanVal');
        if (fanVal) {
            var rpm = telemetry.fan_rpm;
            fanVal.setText(rpm !== null && rpm !== undefined ? String(rpm) : '-');
        }

        // Memory bar (uses lmem_total_mb and lmem_used_mb from backend)
        var memBar = me.down('#memBar');
        var memRange = me.down('#memRange');
        var totalMb = telemetry.lmem_total_mb;
        var usedMb = telemetry.lmem_used_mb;
        if (memBar && totalMb !== null && totalMb !== undefined && totalMb > 0) {
            var used = usedMb || 0;
            var memPct = Math.min(used / totalMb, 1);
            var totalGiB = (totalMb / 1024).toFixed(1);
            var usedGiB = (used / 1024).toFixed(1);
            var memText = usedGiB + ' GiB / ' + totalGiB + ' GiB (' + Math.round(memPct * 100) + '%)';
            memBar.updateProgress(memPct, memText);
            if (memRange) {
                memRange.setText('0  \u2015  ' + totalGiB + ' GiB');
            }
        }
    },

    clearDisplay: function() {
        var me = this;
        var tempBar = me.down('#tempBar');
        if (tempBar) { tempBar.updateProgress(0, '-'); }
        var powerVal = me.down('#powerVal');
        if (powerVal) { powerVal.setText('-'); }
        var clockVal = me.down('#clockVal');
        if (clockVal) { clockVal.setText('-'); }
        var clockMax = me.down('#clockMax');
        if (clockMax) { clockMax.setText(''); }
        var fanVal = me.down('#fanVal');
        if (fanVal) { fanVal.setText('-'); }
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
 * ModifyVfsDialog — modal window for VF count + per-VF LMEM management
 * ========================================================================= */

Ext.define('PVE.window.ModifyVfsDialog', {
    extend: 'Ext.window.Window',
    alias: 'widget.pveModifyVfsDialog',

    title: gettext('Modify Virtual Functions'),
    width: 600,
    modal: true,
    resizable: true,
    layout: { type: 'vbox', align: 'stretch' },
    bodyPadding: 10,

    config: {
        pveSelNode: null,
        deviceRecord: null
    },

    initComponent: function() {
        var me = this;
        var rec = me.deviceRecord;
        var deviceName = rec ? rec.get('device_name') : '-';
        var bdf = rec ? rec.get('bdf') : '-';
        var totalVfs = rec ? (rec.get('sriov_maxvfs') || 0) : 0;
        var currentNumVfs = rec ? (rec.get('sriov_numvfs') || 0) : 0;
        var telemetry = rec ? rec.get('telemetry') : null;
        var lmemTotalMb = telemetry ? (telemetry.lmem_total_mb || 0) : 0;
        var lmemTotalGib = lmemTotalMb / 1024;

        me.lmemTotalGib = lmemTotalGib;
        me.totalVfs = totalVfs;
        // vfRows stores { vfIndex, lmemGib, assigned, vmid } for each current VF row
        me.vfRows = [];

        me.items = [
            {
                xtype: 'displayfield',
                fieldLabel: gettext('Device'),
                labelWidth: 160,
                value: Ext.htmlEncode(deviceName + ' (' + bdf + ')')
            },
            {
                xtype: 'displayfield',
                fieldLabel: gettext('Total LMEM'),
                labelWidth: 160,
                value: lmemTotalGib > 0 ? lmemTotalGib.toFixed(2) + ' GiB' : gettext('Unknown')
            },
            {
                xtype: 'numberfield',
                itemId: 'numVfsField',
                fieldLabel: gettext('Number of VFs'),
                labelWidth: 160,
                name: 'num_vfs',
                value: currentNumVfs,
                minValue: 0,
                maxValue: totalVfs,
                allowBlank: false,
                listeners: {
                    change: function(field, newVal) {
                        me.onVfCountChange(newVal);
                    }
                }
            },
            {
                xtype: 'fieldset',
                title: gettext('Per-VF LMEM Allocation (GiB)'),
                itemId: 'vfLmemFieldset',
                layout: { type: 'vbox', align: 'stretch' },
                items: []
            },
            {
                xtype: 'checkbox',
                itemId: 'persistCb',
                fieldLabel: gettext('Persist across reboots'),
                labelWidth: 160,
                checked: true,
                inputValue: 1,
                uncheckedValue: 0
            }
        ];

        me.buttons = [
            {
                text: gettext('Cancel'),
                handler: function() { me.close(); }
            },
            {
                xtype: 'button',
                text: gettext('Apply'),
                itemId: 'applyBtn',
                iconCls: 'fa fa-check',
                handler: function() { me.doApply(); }
            }
        ];

        me.callParent();
    },

    /**
     * Called after show() to load current VF LMEM data from the VF store.
     * @param {Ext.data.Store} vfStore  The store from the parent vfGrid
     */
    loadVfData: function(vfStore) {
        var me = this;
        var rec = me.deviceRecord;
        var currentNumVfs = rec ? (rec.get('sriov_numvfs') || 0) : 0;

        // Calculate minimum VF count: highest assigned VF index
        var minVfs = 0;
        if (vfStore) {
            vfStore.each(function(vfRec) {
                if (vfRec.get('assigned')) {
                    var idx = vfRec.get('vf_index');
                    if (idx > minVfs) { minVfs = idx; }
                }
            });
        }
        // minVfs is the highest assigned index; we need at least that many VFs
        // (vf_index is 1-based typically, so minVfs == count needed)
        me.down('#numVfsField').setMinValue(minVfs);

        // Build vfRows from store
        me.vfRows = [];
        if (vfStore && currentNumVfs > 0) {
            for (var i = 1; i <= currentNumVfs; i++) {
                var vfRec = vfStore.findRecord('vf_index', i);
                var lmemBytes = vfRec ? Number(vfRec.get('lmem_quota')) : 0;
                var lmemGib = lmemBytes > 0 ? lmemBytes / (1024 * 1024 * 1024) : 0;
                var assigned = vfRec ? !!vfRec.get('assigned') : false;
                var vmid = vfRec ? vfRec.get('vmid') : null;
                me.vfRows.push({
                    vfIndex: i,
                    lmemGib: lmemGib,
                    assigned: assigned,
                    vmid: vmid
                });
            }
        }

        me.rebuildVfRows();
    },

    /**
     * Called when the VF count spinner changes.
     */
    onVfCountChange: function(newCount) {
        var me = this;
        newCount = parseInt(newCount, 10) || 0;
        // Enforce upper bound
        if (newCount > me.totalVfs) {
            newCount = me.totalVfs;
            me.down('#numVfsField').setValue(newCount);
            return;
        }
        // Enforce lower bound: cannot go below highest assigned VF index
        var minVfs = 0;
        me.vfRows.forEach(function(r) {
            if (r.assigned && r.vfIndex > minVfs) { minVfs = r.vfIndex; }
        });
        if (newCount < minVfs) {
            newCount = minVfs;
            me.down('#numVfsField').setValue(newCount);
            return;
        }
        if (newCount < 0) {
            newCount = 0;
            me.down('#numVfsField').setValue(0);
            return;
        }
        var oldCount = me.vfRows.length;

        if (newCount > oldCount) {
            // Add new VF rows (placeholder, will be redistributed below)
            for (var i = oldCount + 1; i <= newCount; i++) {
                me.vfRows.push({
                    vfIndex: i,
                    lmemGib: 0,
                    assigned: false,
                    vmid: null
                });
            }
        } else if (newCount < oldCount) {
            // Remove trailing VFs
            me.vfRows = me.vfRows.slice(0, newCount);
        }

        // Redistribute all available LMEM evenly among unassigned VFs
        var assignedLmem = 0;
        var unassignedCount = 0;
        me.vfRows.forEach(function(r) {
            if (r.assigned) {
                assignedLmem += r.lmemGib;
            } else {
                unassignedCount++;
            }
        });
        var availableLmem = me.lmemTotalGib - assignedLmem;
        var shareEach = unassignedCount > 0 ? availableLmem / unassignedCount : 0;
        shareEach = Math.max(Math.floor(shareEach * 100) / 100, 0.125);
        me.vfRows.forEach(function(r) {
            if (!r.assigned) {
                r.lmemGib = shareEach;
            }
        });

        me.rebuildVfRows();
    },

    /**
     * Rebuild the per-VF LMEM number fields in the fieldset.
     */
    rebuildVfRows: function() {
        var me = this;
        var fieldset = me.down('#vfLmemFieldset');
        if (!fieldset) { return; }

        fieldset.removeAll(true);

        me.vfRows.forEach(function(row, idx) {
            var label = gettext('VF') + ' ' + row.vfIndex;
            if (row.assigned && row.vmid) {
                label += ' <span style="color:#26a826;">[VM ' + Ext.htmlEncode(String(row.vmid)) + ']</span>';
            } else if (row.assigned) {
                label += ' <span style="color:#26a826;">[' + gettext('Assigned') + ']</span>';
            }

            fieldset.add({
                xtype: 'container',
                layout: { type: 'hbox', align: 'middle' },
                margin: '2 0',
                items: [
                    {
                        xtype: 'label',
                        html: label,
                        width: 160,
                        style: row.assigned ? 'font-weight:bold;' : ''
                    },
                    {
                        xtype: 'numberfield',
                        itemId: 'vfLmem_' + row.vfIndex,
                        flex: 1,
                        value: row.lmemGib,
                        minValue: 0.125,
                        maxValue: me.lmemTotalGib,
                        decimalPrecision: 2,
                        step: 0.5,
                        disabled: row.assigned,
                        listeners: {
                            change: (function(vfIdx) {
                                return function(field, newVal) {
                                    var val = parseFloat(newVal) || 0;
                                    // Check if total would exceed max
                                    var otherSum = 0;
                                    me.vfRows.forEach(function(r) {
                                        if (r.vfIndex !== vfIdx) { otherSum += r.lmemGib; }
                                    });
                                    var maxForThis = Math.floor((me.lmemTotalGib - otherSum) * 100) / 100;
                                    if (val > maxForThis) {
                                        val = maxForThis;
                                        field.setValue(val);
                                    }
                                    me.vfRows[vfIdx - 1].lmemGib = val;
                                    me.updateLmemSummary();
                                };
                            }(row.vfIndex))
                        }
                    },
                    {
                        xtype: 'label',
                        text: 'GiB',
                        margin: '0 0 0 6'
                    }
                ]
            });
        });

        if (me.vfRows.length === 0) {
            fieldset.add({
                xtype: 'label',
                text: gettext('No VFs configured. Set the VF count above to allocate.'),
                style: 'color:#888;font-style:italic;'
            });
        }

        // Add LMEM usage summary
        fieldset.add({
            xtype: 'label',
            itemId: 'lmemSummary',
            margin: '8 0 0 0',
            style: 'font-weight:bold;'
        });
        me.updateLmemSummary();
    },

    updateLmemSummary: function() {
        var me = this;
        var totalUsed = 0;
        me.vfRows.forEach(function(r) { totalUsed += r.lmemGib; });
        var remaining = me.lmemTotalGib - totalUsed;
        var label = me.down('#lmemSummary');
        if (label) {
            var colour = remaining < 0 ? '#e84040' : '#26a826';
            label.setHtml(
                gettext('Total allocated') + ': ' +
                '<span style="color:' + colour + ';">' +
                totalUsed.toFixed(2) + ' / ' + me.lmemTotalGib.toFixed(2) + ' GiB' +
                '</span>' +
                ' (' + remaining.toFixed(2) + ' GiB ' + gettext('remaining') + ')'
            );
        }
    },

    doApply: function() {
        var me = this;
        var nodeName = me.pveSelNode && me.pveSelNode.data ? me.pveSelNode.data.node : undefined;
        var bdf = me.deviceRecord ? me.deviceRecord.get('bdf') : null;
        if (!nodeName || !bdf) { return; }

        var numVfsField = me.down('#numVfsField');
        var newNumVfs = parseInt(numVfsField.getValue(), 10) || 0;
        var currentNumVfs = me.deviceRecord ? (me.deviceRecord.get('sriov_numvfs') || 0) : 0;

        // Final validation: enforce bounds
        var totalLmem = 0;
        me.vfRows.forEach(function(r) { totalLmem += r.lmemGib; });
        if (totalLmem > me.lmemTotalGib) {
            Ext.Msg.alert(gettext('Error'), Ext.String.format(
                gettext('Total LMEM allocation ({0} GiB) exceeds available ({1} GiB)'),
                totalLmem.toFixed(2), me.lmemTotalGib.toFixed(2)));
            return;
        }
        if (newNumVfs > me.totalVfs) {
            Ext.Msg.alert(gettext('Error'), Ext.String.format(
                gettext('Cannot exceed maximum VF count ({0})'), me.totalVfs));
            return;
        }
        var minVfs = 0;
        me.vfRows.forEach(function(r) {
            if (r.assigned && r.vfIndex > minVfs) { minVfs = r.vfIndex; }
        });
        if (newNumVfs < minVfs) {
            Ext.Msg.alert(gettext('Error'), Ext.String.format(
                gettext('Cannot reduce below {0} VFs — VF{0} is assigned to a VM'), minVfs));
            return;
        }
        var persist = me.down('#persistCb').getValue() ? 1 : 0;

        // Compute lmem_per_vf (backend uses a single value for all VFs)
        // Use the average of per-VF allocations, converted from GiB to bytes
        var lmemParams = {};
        if (newNumVfs > 0 && me.vfRows.length > 0) {
            var totalLmemGib = 0;
            me.vfRows.forEach(function(row) { totalLmemGib += row.lmemGib; });
            var avgLmemBytes = Math.round((totalLmemGib / newNumVfs) * 1024 * 1024 * 1024);
            lmemParams.lmem_per_vf = avgLmemBytes;
        }

        me.setLoading(true);

        var baseUrl = '/nodes/' + encodeURIComponent(nodeName) +
                      '/hardware/xpu/' + encodeURIComponent(bdf) + '/sriov';

        var doPost = function() {
            var postParams = Ext.apply({ num_vfs: newNumVfs, persist: persist }, lmemParams);
            Proxmox.Utils.API2Request({
                url: baseUrl,
                method: 'POST',
                params: postParams,
                success: function() {
                    me.setLoading(false);
                    me.close();
                    me.fireEvent('vfsmodified', me);
                },
                failure: function(response, opts, error) {
                    me.setLoading(false);
                    Ext.Msg.alert(gettext('Error'), Ext.String.format(
                        gettext('Failed to create VFs: {0}'),
                        error || response.htmlStatus
                    ));
                }
            });
        };

        // POST handles all cases: create, modify, and remove (num_vfs=0)
        doPost();
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
                        header: gettext('Page Size'), dataIndex: 'ggtt_quota', width: 120,
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
                        itemId: 'modifyVfsBtn',
                        text: gettext('Modify VFs'),
                        iconCls: 'fa fa-sliders',
                        disabled: true,
                        handler: function() { me.openModifyDialog(); }
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

        var maxVfs = deviceRecord ? (deviceRecord.get('sriov_maxvfs') || 0) : 0;
        if (!maxVfs || maxVfs <= 0) {
            me.hide();
            return;
        }
        me.show();

        // Disable SR-IOV management when PF is assigned to a VM (whole-GPU passthrough)
        var pfAssigned = deviceRecord.get('pf_assigned');
        var pfVmid = deviceRecord.get('pf_vmid');
        if (pfAssigned) {
            me.enable();
            me.setTitle(gettext('SR-IOV Virtual Functions') + ' \u2014 ' +
                Ext.String.format(gettext('GPU assigned to VM {0}'), pfVmid || '?'));
            me.down('#modifyVfsBtn').setDisabled(true);
            me.reloadVfs();
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

                // Enable Modify VFs button only when no VFs are assigned to VMs
                var modifyBtn = me.down('#modifyVfsBtn');
                if (modifyBtn) {
                    var assignedVms = me.deviceRecord ? me.deviceRecord.get('assigned_vms') : [];
                    var hasAssignedVfs = assignedVms && assignedVms.length > 0;
                    modifyBtn.setDisabled(hasAssignedVfs);
                    if (hasAssignedVfs) {
                        modifyBtn.setTooltip(gettext('Cannot modify VFs while VMs are assigned. Stop and detach VMs first.'));
                    } else {
                        modifyBtn.setTooltip('');
                    }
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
                store.removeAll();
                if (Ext.isArray(data) && data.length > 0) {
                    store.loadData(data);
                }
            },
            failure: function() {
                var store = me.down('#vfGrid').getStore();
                store.removeAll();
            }
        });
    },

    openModifyDialog: function() {
        var me = this;
        var dlg = Ext.create('PVE.window.ModifyVfsDialog', {
            pveSelNode: me.pveSelNode,
            deviceRecord: me.deviceRecord
        });
        dlg.on('vfsmodified', function() {
            // Delay reload to let sysfs settle after VF count change
            Ext.defer(function() {
                me.reloadVfs();
                me.reloadSriov();
                me.fireEvent('vfschanged', me);
            }, 2000);
        });
        dlg.show();
        // Load current VF data from the grid store
        var vfStore = me.down('#vfGrid').getStore();
        dlg.loadVfData(vfStore);
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
            title: gettext('GPU'),
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
