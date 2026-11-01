"""Genera el SQL de un evento aparte (por ejemplo Halloween) con sus propias tablas y funciones.

Toma schema.sql + cajas.sql + retiros.sql + horarios.sql (o los archivos que se le pasen) y antepone un prefijo (ej. "hw_") a cada tabla, índice y función,
sin tocar el texto entre comillas (las claves JSON que lee la app quedan iguales).

Uso: python3 supabase/evento.py hw_ > /tmp/hw.sql                 (evento nuevo, todo)
     python3 supabase/evento.py hw_ retiros.sql > /tmp/hw2.sql    (solo un agregado)
"""
import re
import sys
from pathlib import Path

TABLES = ['settings', 'trucks', 'products', 'days', 'orders', 'order_items', 'registers', 'withdrawals']
FUNCTIONS = ['_auth', '_current_day', '_check_pin', '_summary', 'needs_setup', 'setup_admin', 'login',
             'catalog', 'create_order', 'void_order', 'orders_today', 'summary', 'days_list', 'close_day',
             'save_settings', 'save_truck', 'delete_truck', 'save_product', 'delete_product',
             'save_register', 'delete_register', 'create_withdrawal', 'void_withdrawal', 'withdrawals_today']


def prefix_code(code, pre):
    code = re.sub(r'\b(create (?:unique )?index )(\w+)', lambda m: m.group(1) + pre + m.group(2), code)
    for f in FUNCTIONS:
        code = re.sub(r'(?<![\w.])' + re.escape(f) + r'(?=\s*\()', pre + f, code)
    for t in TABLES:
        code = re.sub(r'(?<![\w.])' + t + r'\b', pre + t, code)
    return code


def prefix_sql(sql, pre):
    # Alterna código / texto entre comillas simples: solo se toca el código.
    parts = re.split(r"('(?:[^']|'')*')", sql)
    return ''.join(p if i % 2 else prefix_code(p, pre) for i, p in enumerate(parts))


if __name__ == '__main__':
    pre = sys.argv[1]
    here = Path(__file__).parent
    files = sys.argv[2:] or ['schema.sql', 'cajas.sql', 'retiros.sql', 'horarios.sql']
    sql = '\n'.join((here / f).read_text() for f in files)
    print(prefix_sql(sql, pre))
