#!/bin/bash
# Mac offline sorter; local Python 3 standard library; NO network/API calls.
set -euo pipefail
if ! command -v python3 >/dev/null 2>&1; then
  echo "未找到 Python 3。请先安装 Python 3（Mac 系统环境依安装情况而异）。"
  read -r -p "按回车关闭…" _ || true
  exit 1
fi
python3 - "$@" <<'PYTHON_EOF'
# -*- coding: utf-8 -*-
"""本地电网照片分类；Python 标准库、无网络、只复制、不覆盖。"""
import csv
import hashlib
import re
import shutil
import zipfile
from collections import Counter, defaultdict
from pathlib import Path
from xml.etree import ElementTree as ET

# 屏柜照片来源第二张表，其他四类来源第一张表；不跨表只按编号匹配。
CATEGORIES = {
    '国家电网资产照片': ('first', '电网资产标签（国家电网资产标签）'),
    '主控分支安装情况拍照': ('first', '监控或通信（主控／分支安装情况拍照）'),
    '屏柜照片': ('second', '屏柜照片'),
    '强电接入方式照片': ('first', '强电接入方式照片'),
    '目标网络设备照片': ('first', '目标网络设备照片'),
}
IMAGE_EXTENSIONS = {'.jpg', '.jpeg', '.png', '.bmp', '.heic', '.webp', '.tif', '.tiff'}
NAME_RX = re.compile(r'^(\d+)(?:\s*[（(](\d+)[）)])?$')
NS = {'m': 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'}
HEADERS = {'文本', '变电站', '屏柜名称'}

def key_name(value):
    return re.sub(r'[\s_／/（）()\-]+', '', str(value)).lower()

def safe_name(value):
    name = str(value or '').strip()
    if not name or name in ('.', '..'):
        raise ValueError('屏柜名称或变电站为空')
    name = re.sub(r'[<>:"/\\|?*\x00-\x1f]', '＿', name).rstrip('. ')
    if not name or name in ('.', '..'):
        raise ValueError('非法目录名')
    return name

def file_rows(path):
    """读取 XLSX 或 CSV；返回每个 sheet 对应的行列表，不依赖第三方包。"""
    p = Path(path)
    if p.suffix.lower() == '.csv':
        for enc in ('utf-8-sig', 'gb18030', 'utf-16'):
            try:
                text = p.read_text(encoding=enc)
                return [[(i, {j: value for j, value in enumerate(row)}) for i, row in enumerate(csv.reader(text.splitlines()), start=1)]]
            except UnicodeError:
                continue
        raise ValueError(f'无法识别 CSV 编码: {p}')
    if p.suffix.lower() not in ('.xlsx', '.xlsm'):
        raise ValueError(f'只支持 xlsx、xlsm 和 CSV，不支持旧版 xls: {p}')
    sheets = []
    with zipfile.ZipFile(p) as z:
        ss = []
        if 'xl/sharedStrings.xml' in z.namelist():
            root = ET.fromstring(z.read('xl/sharedStrings.xml'))
            for si in root.findall('m:si', NS):
                ss.append(''.join(el.text or '' for el in si.findall('.//m:t', NS)))
        paths = [x for x in z.namelist() if re.fullmatch(r'xl/worksheets/sheet\d+\.xml', x)]
        if not paths:
            raise ValueError(f'文件里没有可读取的工作表：{p}')
        for x in sorted(paths, key=lambda x: int(re.search(r'sheet(\d+)', x).group(1))):
            root = ET.fromstring(z.read(x))
            rows = []
            for r in root.findall('.//m:sheetData/m:row', NS):
                cells = {}
                for c in r.findall('m:c', NS):
                    col = re.match(r'[A-Z]+', c.attrib.get('r',''))
                    if not col: continue
                    ci = 0
                    for letter in col.group(): ci = ci*26 + ord(letter) - 64
                    v = c.find('m:v', NS)
                    if c.get('t') == 'inlineStr':
                        value = ''.join(el.text or '' for el in c.findall('.//m:t', NS))
                    elif v is None: value = ''
                    elif c.get('t') == 's': value = ss[int(v.text)]
                    else: value = v.text or ''
                    cells[ci-1] = value
                if cells and any(str(v).strip() for v in cells.values()):
                    rows.append((int(r.get('r', '0')), cells))
            sheets.append(rows)
    return sheets

def normalize_id(s):
    s = str(s or '').strip()
    return re.sub(r'\.0+$', '', s)

def load_ledger(path, profile, noheader_cabinet='D'):
    """有表头自动识别；无表头第一表 A/B/C，第二表默认 A/B/D。"""
    raw = file_rows(path)
    records = []
    issues = []
    headers_found = False
    for sheet_no, rows in enumerate(raw, start=1):
        cols = None
        header_at = None
        for ri, cells in rows:
            names = {key_name(v): c for c,v in cells.items() if str(v).strip()}
            if all(key_name(h) in names for h in HEADERS):
                cols = tuple(names[key_name(h)] for h in ('文本','变电站','屏柜名称'))
                header_at = ri
                headers_found = True
                break
        if cols is None:
            # 无表头的明确结构（本次上传的第一张表已验证是 A/B/C）
            cabinet_col = 2 if profile == 'first' else {'C':2, 'D':3}.get(noheader_cabinet, 3)
            cols = (0,1,cabinet_col)
        for ri, cells in rows:
            if header_at is not None and ri <= header_at: continue
            k = normalize_id(cells.get(cols[0], ''))
            station = str(cells.get(cols[1], '')).strip()
            panel = str(cells.get(cols[2], '')).strip()
            if not k and not station and not panel: continue
            if not k.isdigit() or not station or not panel:
                issues.append(f'工作表{sheet_no} 第{ri}行：缺编号、变电站或屏柜（跳过）')
                continue
            try:
                records.append((k, safe_name(station), safe_name(panel)))
            except ValueError as e:
                issues.append(f'工作表{sheet_no} 第{ri}行：{e}')
    if not records:
        raise ValueError('未发现有效记录。请检查实际工作表数据以及无表头时的屏柜列位置。')
    lookup = defaultdict(set)
    for k,station,panel in records:
        lookup[k].add((station,panel))
    return lookup, records, issues, headers_found

def load_manifest_csv(path):
    lookup = defaultdict(set)
    records=[]
    with Path(path).open('r',encoding='utf-8-sig',newline='') as f:
        for r in csv.DictReader(f):
            k=normalize_id(r['编号']); station=safe_name(r['变电站']); panel=safe_name(r['屏柜名称'])
            lookup[k].add((station,panel))
            records.append((k,station,panel))
    if not records: raise ValueError('映射清单为空')
    return lookup,records,[],True

def detect_category(photo, source_root):
    parts = photo.relative_to(source_root).parts[:-1]
    if not parts:
        parts=(source_root.name,)
    matches = set()
    for part in parts:
        norm = key_name(part)
        for src, info in CATEGORIES.items():
            if norm == key_name(src) or (src=='国家电网资产照片' and norm==key_name('国家电网资产标签')):
                matches.add(src)
    return next(iter(matches)) if len(matches)==1 else None

def checksum(p):
    h=hashlib.sha256()
    with Path(p).open('rb') as f:
        for block in iter(lambda: f.read(1024*512),b''): h.update(block)
    return h.digest()

def build_plan(source_root, output_root, first_map, second_map=None):
    source_root=Path(source_root).resolve(); output_root=Path(output_root).resolve()
    if not source_root.is_dir(): raise ValueError('照片来源目录不存在')
    if source_root==output_root or source_root in output_root.parents or output_root in source_root.parents:
        raise ValueError('照片来源目录与输出目录不能互相包含，避免重复扫描或误操作')
    manifests = {'first':first_map, 'second':second_map}
    used = set(); plan=[]
    for photo in sorted(source_root.rglob('*')):
        if not photo.is_file() or photo.is_symlink() or photo.suffix.lower() not in IMAGE_EXTENSIONS: continue
        cat = detect_category(photo,source_root)
        status='待核对'; reason=''; target=None
        if cat is None: reason='来源目录不是五种照片类型之一，或出现多重类别'
        else:
            match = NAME_RX.fullmatch(photo.stem.strip())
            if not match: reason='图片文件名无法提取编号（应为17.jpg或17(1).jpeg等）'
            else:
                ledger_type, folder_name = CATEGORIES[cat]
                lookup = manifests.get(ledger_type)
                if lookup is None: reason=f'缺少对应的{"屏柜信息表" if ledger_type=="second" else "终端设备安装信息表"}，不允许跨表猜测'
                else:
                    places = lookup.get(match.group(1),set())
                    if len(places)!=1: reason=f'编号在对应表匹配到{len(places)}个不同屏柜'
                    else:
                        station, panel = next(iter(places))
                        target = output_root/station/panel/folder_name/photo.name
                        low = str(target).casefold()
                        if low in used: status='冲突'; reason='本批目标文件路径重复'
                        elif target.exists():
                            if target.is_file() and checksum(photo)==checksum(target):
                                status='已存在相同照片'; reason='以前已复制相同文件，本次跳过'
                            else: status='冲突'; reason='目标位置已有同名不同内容文件，不覆盖'
                        else: status='可复制'; used.add(low)
        plan.append(dict(status=status,original=str(photo),target=str(target) if target else '',reason=reason,category=cat or '未知'))
    return plan

def save_report(plan,path):
    p=Path(path);p.parent.mkdir(parents=True,exist_ok=True)
    with p.open('w',encoding='utf-8-sig',newline='') as f:
        w=csv.DictWriter(f, fieldnames=['status','original','target','reason','category'])
        w.writeheader();w.writerows(plan)

def copy_plan(plan):
    outcomes=Counter()
    for r in plan:
        if r['status']!='可复制':continue
        src=Path(r['original']); dst=Path(r['target']); dst.parent.mkdir(parents=True,exist_ok=True)
        created = False
        try:
            with src.open('rb') as inp, dst.open('xb') as out:
                created = True
                shutil.copyfileobj(inp,out,1024*1024)
            r['status'] = '已复制'
            r['reason'] = ''
            outcomes['已复制']+=1
        except FileExistsError:
            r['status'] = '复制期间发现同名文件'
            r['reason'] = '目标已被其他程序或上一次运行创建，本次跳过，未覆盖'
            outcomes['跳过同名文件']+=1
        except Exception as exc:
            # 中途复制失败的非完整目的文件应该清理，避免将损坏图片当成功导入
            if created and dst.exists():
                try:dst.unlink()
                except OSError:pass
            r['status'] = '复制错误'
            r['reason'] = f'{type(exc).__name__}: {exc}'
            print('复制失败：', src, ' -> ', dst, '原因：', r['reason'], flush=True)
            outcomes['复制错误']+=1
    return outcomes

import subprocess, json, sys

def apple(script):
    r = subprocess.run(['osascript', '-e', script], capture_output=True, text=True)
    if r.returncode:
        raise RuntimeError('已取消，或 macOS 未允许访问所选文件。' + r.stderr.strip())
    return r.stdout.strip()

def apple_str(s):
    return json.dumps(s, ensure_ascii=False)

def pick_file(prompt):
    return Path(apple('POSIX path of (choose file with prompt ' + apple_str(prompt) + ')'))

def pick_folder(prompt):
    return Path(apple('POSIX path of (choose folder with prompt ' + apple_str(prompt) + ')'))

def notify(message, title='电网照片离线分类'):
    try:
        apple('display dialog ' + apple_str(message) + ' with title ' + apple_str(title) + ' buttons {"确定"} default button "确定"')
    except Exception:
        pass

def main():
    try:
        first_file = pick_file('请选择【变电站终端设备安装信息表】Excel 文件（第一张表）')
        first_map, first_records, warnings, _ = load_ledger(first_file, 'first')
        second_file = None
        choice = apple('button returned of (display dialog "是否有第二张【变电站屏柜信息表】？屏柜照片仅按第二张表匹配；暂时没有可跳过。" buttons {"暂不提供", "选择第二张表"} default button "暂不提供")')
        second_map = None
        second_records = []
        if choice == '选择第二张表':
            second_file = pick_file('请选择第二张【变电站屏柜信息表】Excel')
            second_map, second_records, w2, _ = load_ledger(second_file, 'second', 'D')
            warnings.extend(w2)
        photos = pick_folder('请选择包含五类照片来源文件夹的【总目录】')
        output = pick_folder('请选择要存放 59 个变电站的【输出目录】（不可与照片源互相包含）')
        plan = build_plan(photos, output, first_map, second_map)
        stats = Counter(x['status'] for x in plan)
        report = Path.home() / 'Desktop' / '电网照片分类_预览.csv'
        save_report(plan, report)
        print('已生成预览：', report)
        print('第一张表有效记录：', len(first_records), '第二张表：', len(second_records))
        print('扫描照片：', len(plan), '统计：', dict(stats))
        if warnings:
            print('台账异常：', len(warnings), '条，首批：', warnings[:5])
        subprocess.run(['open', str(report)], check=False)
        if not plan:
            notify('扫描结果为 0 张照片：没有找到支持的图片文件。请检查选择的照片总目录，里面是否有五个照片类型子文件夹。不会创建空文件夹。')
            return
        if stats.get('可复制', 0) == 0:
            reasons = Counter(x['reason'] for x in plan if x['status'] in ('待核对','冲突'))
            examples = '\\n'.join(f'{reason}: {count} 张' for reason,count in reasons.most_common(4))
            print('没有可复制的照片，未创建或修改归档目录。请检查桌面【电网照片分类_预览.csv】。')
            print('主要原因：', reasons.most_common(10))
            notify('扫描了 '+str(len(plan))+' 张图片，但【可复制 = 0】。\\n没有建立目录或复制照片。\\n\\n主要原因：\\n'+examples+'\\n\\n请打开桌面的【电网照片分类_预览.csv】查看具体照片和原因。')
            return
        message = (f'已读取第一表 {len(first_records)} 条、第二表 {len(second_records)} 条。\n'
                   f'扫描照片 {len(plan)} 张，其中可复制 {stats.get("可复制",0)} 张，'
                   f'待核对 {stats.get("待核对",0)} 张、冲突 {stats.get("冲突",0)} 张。\n\n'
                   '预览报告已在桌面打开。请检查每张照片的对应路径；\n'
                   '只有点击【确认复制】才会生成变电站/屏柜/五类文件夹并复制照片。\n'
                   '如果第二张表未提供，屏柜照片不会被猜测归档。')
        choice = apple('button returned of (display dialog ' + apple_str(message) +
                       ' with title "电网照片分类 · 预览检查" buttons {"取消", "确认复制"} default button "取消" with icon caution)')
        if choice != '确认复制':
            print('已取消，照片和输出目录未修改。')
            return
        # Reevaluate target availability, since the preview could have been reviewed for some time.
        plan = build_plan(photos, output, first_map, second_map)
        records = first_records + second_records
        stations = {st for _,st,_ in records}
        panels = {(st,cb) for _,st,cb in records}
        for st, cb in panels:
            for _,folder_name in CATEGORIES.values():
                (output/st/cb/folder_name).mkdir(parents=True, exist_ok=True)
        print('已创建变电站：', len(stations), '个；屏柜：', len(panels), '个。')
        result = copy_plan(plan)
        saved = Path.home() / 'Desktop' / '电网照片分类_执行报告.csv'
        save_report(plan, saved)
        print('复制结果：', dict(result), '报告：', saved)
        subprocess.run(['open', str(saved)], check=False)
        subprocess.run(['open', str(output)], check=False)
        failed = result.get('复制错误',0)
        completed = result.get('已复制',0)
        if failed:
            notify(f'本次实际复制 {completed} 张，失败 {failed} 张。\\n请查看桌面的【电网照片分类_执行报告.csv】中「复制错误」行及原因。没有删除原图。', '分类尚未全部完成')
        else:
            notify(f'本次实际复制 {completed} 张，未匹配照片和冲突文件已在桌面的执行报告中列出。\\n原始照片没有删除，目标已有同名照片不会覆盖。', '分类复制完成')
    except Exception as e:
        print('错误：', str(e), file=sys.stderr)
        notify('未执行归档：'+str(e), '分类程序提示')
        raise SystemExit(1)

if __name__ == '__main__':
    if '--test' in sys.argv:
        print('程序解析通过；请用本机 Excel 和照片目录进行验证。')
    else:
        main()

PYTHON_EOF